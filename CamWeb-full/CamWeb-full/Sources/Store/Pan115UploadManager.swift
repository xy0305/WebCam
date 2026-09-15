import Foundation
import CommonCrypto

@MainActor
final class Pan115UploadManager: NSObject, ObservableObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = Pan115UploadManager()
    struct Item: Identifiable {
        let id: UUID
        let file: URL
        var name: String
        var total: Int64
        var sent: Int64 = 0
        var state = "准备中"
        var error: String?
        var speed: Double = 0
        var lastSampleBytes: Int64 = 0
        var lastSampleDate = Date()
    }
    @Published private(set) var items: [Item] = []
    private lazy var session: URLSession = { let c = URLSessionConfiguration.background(withIdentifier: "com.xy0305.CamWeb.115upload"); c.isDiscretionary = false; c.sessionSendsLaunchEvents = true; return URLSession(configuration: c, delegate: self, delegateQueue: nil) }()
    private var taskMap: [Int: UUID] = [:]

    func enqueue(_ file: URL) {
        guard let cookie = Pan115Session.shared.cookieHeader, let cid = Pan115Session.shared.validCID else { return }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let id = UUID(); items.append(Item(id: id, file: file, name: file.lastPathComponent, total: size))
        Task { await prepare(id: id, cookie: cookie, cid: cid) }
    }
    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let taskIDs = taskMap.filter { $0.value == id }.map(\.key)
        session.getAllTasks { tasks in tasks.filter { taskIDs.contains($0.taskIdentifier) }.forEach { $0.cancel() } }
        items[i].state = "已取消"
    }
    func retry(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state == "上传失败" else { return }
        items.removeAll { $0.id == id }
        enqueue(item.file)
    }
    func removeFinished(_ id: UUID) { items.removeAll { $0.id == id } }
    private func set(_ id: UUID, _ state: String, _ error: String? = nil) { if let i=items.firstIndex(where:{$0.id==id}) { items[i].state=state; items[i].error=error } }

    private func prepare(id: UUID, cookie: String, cid: String) async {
        guard let item = items.first(where: {$0.id == id}) else{return}; set(id,"计算 SHA-1…")
        do {
            let fileid = try await Task.detached { try Digest115.sha1(item.file) }.value
            let preid = try await Task.detached { try Digest115.sha1(item.file, count: min(UInt64(item.total), 128*1024)) }.value
            set(id,"请求 115 上传…")
            let client = One15Client(cookie: cookie)
            let info = try await client.uploadInfo()
            guard item.total <= info.limit else { throw One15Error.message("文件超过 115 上传限制") }
            let initResp = try await client.initialize(file: item.file, name: item.name, cid: cid, size: item.total, fileid: fileid, preid: preid, userID: info.userID, userkey: info.userkey)
            if initResp.status == 2 { set(id,"秒传完成"); return }
            guard let bucket = initResp.bucket,
                  let object = initResp.object,
                  let callback = initResp.callback?.callback,
                  let callbackVar = initResp.callback?.callbackVar else {
                throw One15Error.message("115 未返回完整 OSS 上传参数")
            }
            let sts = try await client.ossToken(); set(id,"正在上传")
            let request = try OSS115.request(bucket: bucket, object: object, file: item.file, access: sts, callback: callback, callbackVar: callbackVar)
            let task = session.uploadTask(with: request, fromFile: item.file); taskMap[task.taskIdentifier]=id; task.resume()
        } catch { set(id,"上传失败", error.localizedDescription) }
    }
    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        Task { @MainActor in
            guard let id = self.taskMap[task.taskIdentifier], let i = self.items.firstIndex(where: { $0.id == id }) else { return }
            let now = Date(), elapsed = now.timeIntervalSince(self.items[i].lastSampleDate)
            if elapsed >= 0.35 {
                self.items[i].speed = Double(totalBytesSent - self.items[i].lastSampleBytes) / elapsed
                self.items[i].lastSampleBytes = totalBytesSent
                self.items[i].lastSampleDate = now
            }
            self.items[i].sent = totalBytesSent
            self.items[i].total = totalBytesExpectedToSend
        }
    }
    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { Task { @MainActor in guard let id=self.taskMap.removeValue(forKey:task.taskIdentifier) else{return}; self.set(id,error == nil ? "上传完成" : "上传失败",error?.localizedDescription) } }
}

enum One15Error: LocalizedError { case message(String); var errorDescription:String? { if case let .message(s)=self{return s};return nil } }
private struct One15Info { let userID:Int64; let userkey:String; let limit:Int64 }
private struct One15Init: Decodable {
    struct Callback: Decodable {
        let callback: String
        let callbackVar: String
        enum CodingKeys: String, CodingKey { case callback; case callbackVar = "callback_var" }
    }
    let status: Int?
    let bucket: String?
    let object: String?
    let callback: Callback?
    let sign_key: String?
    let sign_check: String?
    let statuscode: Int?
    let statusmsg: String?
}
struct One15STS: Decodable { let AccessKeyId:String?; let AccessKeyID:String?; let AccessKeySecret:String; let SecurityToken:String; var key:String { AccessKeyId ?? AccessKeyID ?? "" } }
private final class One15Client {
 let cookie:String; init(cookie:String){self.cookie=cookie}
 func req(_ url:URL, _ method:String="GET", _ body:Data?=nil)->URLRequest { var r=URLRequest(url:url);r.httpMethod=method;r.httpBody=body;r.setValue(cookie,forHTTPHeaderField:"Cookie");r.setValue("Mozilla/5.0 115Browser/27.0.5.7",forHTTPHeaderField:"User-Agent");return r }
 func data(_ r:URLRequest) async throws -> Data {
  let (d,res)=try await URLSession.shared.data(for:r)
  guard let h=res as? HTTPURLResponse else { throw One15Error.message("115 未返回 HTTP 响应") }
  guard (200..<300).contains(h.statusCode) else {
   let message=String(data:d,encoding:.utf8)?.prefix(300) ?? ""
   throw One15Error.message("115 HTTP \(h.statusCode)：\(message)")
  }
  return d
 }
 func uploadInfo() async throws -> One15Info { var r=req(URL(string:"https://proapi.115.com/app/uploadinfo")!,"POST");r.setValue("application/json;charset=UTF-8",forHTTPHeaderField:"Content-Type");let d=try await data(r);let o=try JSONSerialization.jsonObject(with:d) as? [String:Any] ?? [:];guard let uid=(o["user_id"] as? NSNumber)?.int64Value,let key=o["userkey"] as? String else{throw One15Error.message("115 Cookie 已失效")};return One15Info(userID:uid,userkey:key,limit:(o["size_limit"] as? NSNumber)?.int64Value ?? Int64.max) }
 func ossToken() async throws -> One15STS {
  let tokenData = try await data(req(URL(string:"https://uplb.115.com/3.0/gettoken.php")!))
  return try JSONDecoder().decode(One15STS.self, from: tokenData)
 }
 func initialize(file:URL,name:String,cid:String,size:Int64,fileid:String,preid:String,userID:Int64,userkey:String) async throws -> One15Init {
  let target="U_1_\(cid)";let sig=Digest115.sha1Text("\(userID)\(fileid)\(target)0");let signature=Digest115.sha1Text("\(userkey)\(sig)000000");let crypto=One15Crypto();var sk="",sv=""
  while true { let t=Int64(Date().timeIntervalSince1970*1000);let token=Digest115.md5("Qclm8MGWUv59TnrR0XPg\(fileid)\(size)\(sk)\(sv)\(userID)\(t)\(Digest115.md5(String(userID)))27.0.5.7");var f=["appid":"0","appversion":"27.0.5.7","userid":"\(userID)","filename":name,"filesize":"\(size)","fileid":fileid,"target":target,"sig":signature,"topupload":"true","t":"\(t)","token":token];if !sk.isEmpty {f["sign_key"]=sk;f["sign_val"]=sv};guard let body=crypto.encryptRequest(Form115.encode(f).data(using:.utf8)!) else{throw One15Error.message(crypto.lastFailure() ?? "115 初始化请求加密失败")};var c=URLComponents(string:"https://uplb.115.com/4.0/initupload.php")!;c.queryItems=[URLQueryItem(name:"k_ec",value:try crypto.token(forMilliseconds:t))];var r=req(c.url!,"POST",body);r.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type");let responseData = try await data(r);guard let decrypted=crypto.decryptResponse(responseData) else{throw One15Error.message(crypto.lastFailure() ?? "115 初始化响应解密失败")};let result=try JSONDecoder().decode(One15Init.self,from:decrypted);if result.status==7,let key=result.sign_key,let range=result.sign_check {let a=range.split(separator:"-").compactMap{UInt64($0)};guard a.count==2 else{throw One15Error.message("115 校验范围错误")};sk=key;sv=try Digest115.sha1(file,offset:a[0],count:a[1]-a[0]+1);continue};guard result.status==1 || result.status==2 else{throw One15Error.message(result.statusmsg ?? "115 初始化上传失败")};return result }
 }
}
