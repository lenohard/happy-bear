搜索文件（关键词搜索）
接口描述

本接口用于获取用户指定目录下，包含指定关键字的文件列表。

权限说明

所有API的安全认证一律采用OAuth2.0鉴权认证机制。

鉴权认证机制的详细内容请参见《开发者须知 > 接入流程》。

注意事项

执行请求示例代码时，请将示例代码中的access_token参数替换为自行获取的access_token
请求结构

GET /rest/2.0/xpan/file?method=search HTTP/1.1
Host: pan.baidu.com
请求参数

参数名称	类型	是否必需	示例	参数位置	描述
method	String	是	search	URL参数	本接口固定为search
access_token	String	是	12.a6b7dbd428f731035f771b8d15063f61.86400.1292922000-2346678-124328	URL参数	接口鉴权参数
key	string	是	"day"	URL参数	搜索关键字，最大30字符（UTF8格式）
dir	string	否	/测试目录	URL参数	搜索目录，默认根目录
category	int	否	2	URL参数	文件类型，1 视频、2 音频、3 图片、4 文档、5 应用、6 其他、7 种子
num	int	否	500	URL参数	默认为500，不能修改
recursion	int	否	1	URL参数	是否递归，带这个参数就会递归，否则不递归
web	int	否	0	URL参数	是否展示缩略图信息，带这个参数会返回缩略图信息，否则不展示缩略图信息
device_id	string	否	104771607rs1607808	URL参数	设备ID，设备注册接口下发，硬件设备必传
响应参数

参数名称	类型	描述
has_more	int	是否还有下一页
list	array	文件列表
list[0] ["category"]	int	文件类型
list[0] ["fs_id"]	int	文件在云端的唯一标识
list[0] ["isdir"]	int	是否是目录，0为否，1为是
list[0] ["local_ctime"]	int	文件在客户端创建时间
list[0] ["local_mtime"]	int	文件在客户端修改时间
list[0] ["server_ctime"]	int	文件在服务端创建时间
list[0] ["server_mtime"]	int	文件在服务端修改时间
list[0] ["md5"]	string	云端哈希（非文件真实MD5）
list[0] ["size"]	int	文件大小
list[0] ["thumbs"]	string	缩略图地址
错误码

更多错误码请参考《开发者须知 > 错误码》中“公共错误码”部分。

请求示例

curl示例
curl -L -X GET 'https://pan.baidu.com/rest/2.0/xpan/file?dir=/%E6%B5%8B%E8%AF%95%E7%9B%AE%E5%BD%95&access_token=12.a6b7dbd428f731035f771b8d15063f61.86400.1292922000-2346678-124328&web=1&recursion=1&page=1&num=2&method=search&key=mmexport' \
-H 'User-Agent: pan.baidu.com' 
python 示例
import requests

url = "https://pan.baidu.com/rest/2.0/xpan/file?dir=/测试目录&access_token=12.a6b7dbd428f731035f771b8d15063f61.86400.1292922000-2346678-124328&web=1&recursion=1&page=1&num=2&method=search&key=mmexport"

payload = {}
files = {}
headers = {
  'User-Agent': 'pan.baidu.com'
}

response = requests.request("GET", url, headers=headers, data = payload, files = files)

print(response.text.encode('utf8'))
java示例
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

public class HttpGetRequestExample {
    public static void main(String[] args) {
        try {
            URL url = new URL("https://pan.baidu.com/rest/2.0/xpan/file?dir=/apps/test&access_token=12.a6b7dbd428f731035f771b8d15063f61.86400.1292922000-2346678-124328&web=1&recursion=1&page=1&num=2&method=search&key=mmexport");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            BufferedReader in = new BufferedReader(new InputStreamReader(conn.getInputStream()));
            String inputLine;
            StringBuffer response = new StringBuffer();
            while ((inputLine = in.readLine()) != null) {
                response.append(inputLine);
            }
            in.close();
            System.out.println(response.toString());
        } catch (Exception e) {
            System.out.println(e);
        }
    }
} 
响应示例

{
    "errno": 0,
    "list": [
        {
            "fs_id": 116244312814490,
            "path": "/测试目录/testnac/mmexport1589760367195.gif",
            "server_filename": "mmexport1589760367195.gif",
            "size": 30728,
            "server_mtime": 1596077866,
            "server_ctime": 1594367179,
            "local_mtime": 1589760367,
            "local_ctime": 1589760367,
            "isdir": 0,
            "category": 3,
            "share": 0,
            "oper_id": 2082810368,
            "extent_tinyint1": 0,
            "md5": "fe576033bnd89833c370ab6912246b85",
            "thumbs": {
                "url1": "https://thumbnail0.baidupcs.com/thumbnail/fe576033bnd89833c370ab6912246b85?fid=2082810368-250528-116244312814490&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-AZ9ikmAFZ73LwDcDsrN2kRZ11Uk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c140_u90&quality=100&vuk=2082810368&ft=image",
                "url2": "https://thumbnail0.baidupcs.com/thumbnail/fe576033bnd89833c370ab6912246b85?fid=2082810368-250528-116244312814490&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-AZ9ikmAFZ73LwDcDsrN2kRZ11Uk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c360_u270&quality=100&vuk=2082810368&ft=image",
                "url3": "https://thumbnail0.baidupcs.com/thumbnail/fe576033bnd89833c370ab6912246b85?fid=2082810368-250528-116244312814490&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-AZ9ikmAFZ73LwDcDsrN2kRZ11Uk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c850_u580&quality=100&vuk=2082810368&ft=image",
                "icon": "https://thumbnail0.baidupcs.com/thumbnail/fe576033bnd89833c370ab6912246b85?fid=2082810368-250528-116244312814490&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-AZ9ikmAFZ73LwDcDsrN2kRZ11Uk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c60_u60&quality=100&vuk=2082810368&ft=image"
            }
        },
        {
            "fs_id": 1060489721865574,
            "path": "/测试目录/testnac/mmexport1589760383746.gif",
            "server_filename": "mmexport1589760383746.gif",
            "size": 69326,
            "server_mtime": 1596077866,
            "server_ctime": 1594367178,
            "local_mtime": 1589760383,
            "local_ctime": 1589760383,
            "isdir": 0,
            "category": 3,
            "share": 0,
            "oper_id": 2082810368,
            "extent_tinyint1": 0,
            "md5": "a095133d1qf350ebae1304f28ad3e885",
            "thumbs": {
                "url1": "https://thumbnail0.baidupcs.com/thumbnail/a095133d1qf350ebae1304f28ad3e885?fid=2082810368-250528-1060489721865574&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-m49icWaRz0omTy6TQKrTu3tlhYk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c140_u90&quality=100&vuk=2082810368&ft=image",
                "url2": "https://thumbnail0.baidupcs.com/thumbnail/a095133d1qf350ebae1304f28ad3e885?fid=2082810368-250528-1060489721865574&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-m49icWaRz0omTy6TQKrTu3tlhYk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c360_u270&quality=100&vuk=2082810368&ft=image",
                "url3": "https://thumbnail0.baidupcs.com/thumbnail/a095133d1qf350ebae1304f28ad3e885?fid=2082810368-250528-1060489721865574&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-m49icWaRz0omTy6TQKrTu3tlhYk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c850_u580&quality=100&vuk=2082810368&ft=image",
                "icon": "https://thumbnail0.baidupcs.com/thumbnail/a095133d1qf350ebae1304f28ad3e885?fid=2082810368-250528-1060489721865574&rt=pr&sign=FDTAER-DCb740ccc5511e5e8fedcff06b081203-m49icWaRz0omTy6TQKrTu3tlhYk%3D&expires=8h&chkv=0&chkbd=0&chkpc=&dp-logid=4927522320290083723&dp-callid=0&time=1596164400&size=c60_u60&quality=100&vuk=2082810368&ft=image"
            }
        }
    ],
    "request_id": 4927522320290083723,
    "contentlist": [],
    "has_more": 1
}
