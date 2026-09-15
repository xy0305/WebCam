import Foundation
import CommonCrypto

enum Digest115 {
    static func sha1(_ url: URL, offset: UInt64 = 0, count: UInt64? = nil) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }; try h.seek(toOffset: offset)
        var ctx = CC_SHA1_CTX(); CC_SHA1_Init(&ctx); var left=count
        while left == nil || left! > 0 { let n=min(1024*1024,Int(left ?? 1024*1024)); let d=try h.read(upToCount:n) ?? Data(); if d.isEmpty {break}; d.withUnsafeBytes { CC_SHA1_Update(&ctx,$0.baseAddress,CC_LONG(d.count)) }; if let v=left {left=v-UInt64(d.count)} }
        var out=[UInt8](repeating:0,count:Int(CC_SHA1_DIGEST_LENGTH));CC_SHA1_Final(&out,&ctx);return out.map{String(format:"%02X",$0)}.joined()
    }
    static func sha1Text(_ s:String)->String { var o=[UInt8](repeating:0,count:Int(CC_SHA1_DIGEST_LENGTH));let d=Data(s.utf8);d.withUnsafeBytes{CC_SHA1($0.baseAddress,CC_LONG(d.count),&o)};return o.map{String(format:"%02X",$0)}.joined() }
    static func md5(_ s:String)->String { var o=[UInt8](repeating:0,count:Int(CC_MD5_DIGEST_LENGTH));let d=Data(s.utf8);d.withUnsafeBytes{CC_MD5($0.baseAddress,CC_LONG(d.count),&o)};return o.map{String(format:"%02x",$0)}.joined() }
    static func hmacSHA1(_ s:String,key:String)->String { let data=Data(s.utf8),k=Data(key.utf8);var out=[UInt8](repeating:0,count:Int(CC_SHA1_DIGEST_LENGTH));CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),[UInt8](k),k.count,[UInt8](data),data.count,&out);return Data(out).base64EncodedString() }
}
enum Form115 { static func encode(_ v:[String:String])->String { let a=CharacterSet.alphanumerics.union(.init(charactersIn:"-._"));func e(_ s:String)->String{s.addingPercentEncoding(withAllowedCharacters:a)!.replacingOccurrences(of:"%20",with:"+")};return v.sorted{$0.key<$1.key}.map{"\(e($0.key))=\(e($0.value))"}.joined(separator:"&") } }
enum OSS115 {
 static func request(bucket:String,object:String,file:URL,access:One15STS,callback:String,callbackVar:String)throws->URLRequest {
  let date=DateFormatter.oss.string(from:Date()), path="/\(bucket)/\(object)", host="\(bucket).cn-shenzhen.oss.aliyuncs.com"
  let cb=Data(callback.utf8).base64EncodedString(),cv=Data(callbackVar.utf8).base64EncodedString()
  let headers=["x-oss-callback":cb,"x-oss-callback-var":cv,"x-oss-security-token":access.SecurityToken]
  let canonical=headers.sorted{$0.key<$1.key}.map{"\($0.key):\($0.value)\n"}.joined()
  let sign="PUT\n\n\n\(date)\n\(canonical)\(path)"
  guard let url=URL(string:"https://\(host)/\(object.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? object)") else{throw One15Error.message("OSS 地址无效")}
  var r=URLRequest(url:url);r.httpMethod="PUT";r.setValue("OSS \(access.key):\(Digest115.hmacSHA1(sign,key:access.AccessKeySecret))",forHTTPHeaderField:"Authorization");r.setValue(date,forHTTPHeaderField:"Date");r.setValue(access.SecurityToken,forHTTPHeaderField:"x-oss-security-token");r.setValue(cb,forHTTPHeaderField:"x-oss-callback");r.setValue(cv,forHTTPHeaderField:"x-oss-callback-var");r.setValue("aliyun-sdk-android/2.9.1",forHTTPHeaderField:"User-Agent");return r
 }
}
private extension DateFormatter { static let oss:DateFormatter={let d=DateFormatter();d.locale=Locale(identifier:"en_US_POSIX");d.timeZone=TimeZone(secondsFromGMT:0);d.dateFormat="EEE, dd MMM yyyy HH:mm:ss 'GMT'";return d}() }
