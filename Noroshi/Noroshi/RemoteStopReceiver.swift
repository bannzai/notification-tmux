import AppKit
import Foundation
import Network

/// リモートホストからの Stop hook 通知の受信路 (issue #39)。
/// host ごとに 127.0.0.1 の TCP listener を開き、`ssh -N -R` でリモートの
/// `$HOME/.noroshi.sock` をその listener へフォワードする。リモートの Stop hook は
/// socket へ `session=<enc>&window=@n` の 1 行を書く (scripts/noroshi-hook-stop)。
/// ssh 切断中に発火した通知は再送されず取りこぼす (issue #39 で許容した挙動)。
/// NWListener / ssh Process のライフサイクルを保持するため class にしている。
@MainActor
final class RemoteStopReceiver {
    static let shared = RemoteStopReceiver()

    /// 受信イベントの配送先。reconcile で最新のものに差し替える。
    private var onEvent: ((StopEvent) -> Void)?
    /// host 名 -> 稼働中のフォワーダ。
    private var forwarders: [String: RemoteStopForwarder] = [:]
    /// willTerminate 監視の多重登録を防ぐフラグ。
    private var observesTermination = false

    /// config の host 集合へフォワーダを冪等に一致させる。新規 host は開始し、消えた host は停止する。
    func reconcile(hostNames: [String], onEvent: @escaping (StopEvent) -> Void) {
        self.onEvent = onEvent
        if !observesTermination {
            observesTermination = true
            // アプリ終了時に ssh -N の子プロセスを残さない。
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in RemoteStopReceiver.shared.stopAll() }
            }
        }
        for hostName in hostNames where forwarders[hostName] == nil {
            forwarders[hostName] = RemoteStopForwarder(hostName: hostName) { [weak self] event in
                self?.onEvent?(event)
            }
        }
        for (hostName, forwarder) in forwarders where !hostNames.contains(hostName) {
            forwarder.stop()
            forwarders[hostName] = nil
        }
    }

    /// 全フォワーダを停止する。再度 reconcile すれば同じ状態に戻る (冪等)。
    func stopAll() {
        forwarders.values.forEach { $0.stop() }
        forwarders = [:]
    }
}

/// 1 リモート host 分の受信路: ローカル listener + `ssh -N -R` フォワード + 再接続ループ。
@MainActor
final class RemoteStopForwarder {
    /// フォワード切断後の再接続待ち秒数。再接続の嵐を避けつつ、通知を受けられない時間を短く保つ実用値。
    private static let reconnectDelaySeconds: UInt64 = 5
    /// 1 接続で受け付ける最大バイト数。ペイロードは URL エンコード済み session 名 + window_id で高々数百バイトのため十分。
    private static let maxPayloadBytes = 4096

    private let hostName: String
    private let onEvent: (StopEvent) -> Void
    /// リモートからのフォワード接続を受けるローカル listener (127.0.0.1 のみ)。
    private var listener: NWListener?
    /// 稼働中の `ssh -N -R` プロセス。
    private var sshProcess: Process?
    /// フォワードの確立・再接続ループ。
    private var forwardTask: Task<Void, Never>?
    /// stop() 済みかどうか。以後の再接続を止める。
    private var isStopped = false

    // listener の起動という副作用を初期化と同時に行うため定義している
    init(hostName: String, onEvent: @escaping (StopEvent) -> Void) {
        self.hostName = hostName
        self.onEvent = onEvent
        startListener()
    }

    /// listener・ssh・再接続ループをすべて止める。複数回呼んでも同じ停止状態に収束する (冪等)。
    func stop() {
        isStopped = true
        forwardTask?.cancel()
        forwardTask = nil
        sshProcess?.terminate()
        sshProcess = nil
        listener?.cancel()
        listener = nil
    }

    /// 127.0.0.1 の空きポートで listener を開き、ready になったらフォワードループを始める。
    private func startListener() {
        let parameters = NWParameters.tcp
        // リモートからの経路は ssh フォワードだけにし、LAN の他ホストから直接届かないよう loopback に束縛する。
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        listener.newConnectionHandler = { connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.receive(on: connection, buffered: Data())
                }
                connection.start(queue: .main)
            }
        }
        listener.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard case .ready = state, let port = listener.port, self.forwardTask == nil else { return }
                    self.startForwardLoop(localPort: port.rawValue)
                }
            }
        }
        listener.start(queue: .main)
    }

    /// 接続からペイロードを読み、行ごとに StopEvent へ変換して配送する。
    /// 上限超過や形式不正は黙って捨てる (リモート側プロセスをブロックしない)。
    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxPayloadBytes) { data, _, isComplete, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var buffered = buffered
                    if let data { buffered.append(data) }
                    if buffered.count > Self.maxPayloadBytes || error != nil {
                        connection.cancel()
                        return
                    }
                    // hook は 1 行書いて切断する。改行を受けた時点で処理し、以降は接続を閉じるだけにする。
                    if isComplete || buffered.contains(UInt8(ascii: "\n")) {
                        self.deliver(payloadData: buffered)
                        connection.cancel()
                        return
                    }
                    self.receive(on: connection, buffered: buffered)
                }
            }
        }
    }

    /// 受信バイト列を行単位で StopEvent にし、有効な行だけ配送する。
    private func deliver(payloadData: Data) {
        guard let text = String(data: payloadData, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            if let event = StopEvent(payload: String(line), from: .remote(hostName)) {
                onEvent(event)
            }
        }
    }

    /// `ssh -N -R` を張り、切断されたら間隔を置いて張り直すループを起動する。
    /// ssh の同期実行 (Process.waitUntilExit) を含むため detached で回し、状態の出し入れだけ MainActor で行う。
    private func startForwardLoop(localPort: UInt16) {
        forwardTask = Task.detached(priority: .utility) { [hostName] in
            let client = TmuxClient(host: .remote(hostName))
            while !Task.isCancelled {
                if await self.isStopped { return }
                // -R はリモートパスの `~` を展開しないため $HOME を先に解決する。
                // 前回の socket ファイルが残っていると sshd が bind に失敗するため、毎回消してから張る (冪等)。
                let remoteHome = try? client.runRemoteShell(
                    "rm -f \"$HOME/\(TmuxClient.remoteStopSocketFile)\" && printf %s \"$HOME\""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if let remoteHome, remoteHome.hasPrefix("/") {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: TmuxClient.sshPath)
                    process.arguments = TmuxClient.sshBatchOptions() + [
                        "-N",
                        // フォワードを確立できないまま接続だけ生きる状態を作らない。
                        "-o", "ExitOnForwardFailure=yes",
                        // 無応答の接続を約 1 分で切って再接続ループに戻すための keepalive。
                        "-o", "ServerAliveInterval=15",
                        "-o", "ServerAliveCountMax=4",
                        "-R", "\(remoteHome)/\(TmuxClient.remoteStopSocketFile):127.0.0.1:\(localPort)",
                        hostName,
                    ]
                    do {
                        try process.run()
                        await MainActor.run { self.sshProcess = process }
                        process.waitUntilExit()
                    } catch {
                        // 起動自体の失敗 (ssh 不在等) は下の再接続待ちに合流する
                    }
                    await MainActor.run { self.sshProcess = nil }
                }
                if await self.isStopped { return }
                try? await Task.sleep(nanoseconds: Self.reconnectDelaySeconds * 1_000_000_000)
            }
        }
    }
}
