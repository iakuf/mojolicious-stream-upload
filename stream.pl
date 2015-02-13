use Mojolicious::Lite;
use Digest::MD5 qw(md5_hex);
use Scalar::Util 'weaken';
use File::Basename qw(dirname); 
use File::Spec::Functions qw(catdir catfile);
use Asset::File;
use Mojolicious::Plugin::Config;
use File::Copy;
use Mojo::JSON qw(encode_json);
use IO::File;
use Encode qw(encode_utf8);
use Cwd;
use utf8;
    
our $VERSION = '1.0';
$ENV{MOJO_MAX_MESSAGE_SIZE} = 2147483648;

my $config = plugin Config => {
    file => '/etc/StreamUpload.conf'
};

my $UploadServer    = $config->{UploadServer}   || 'http://125.89.72.212:3009';
my $FileRepository  = $config->{FileRepository} || '/tmp/';
my $CrossOrigins    = $config->{CrossOrigins}   || '*';
my $TokenKey        = $config->{TokenKey}       || 'stream';

app->log->path($config->{log});
app->log->level('debug') if $config->{debug} == 1;

hook after_build_tx => sub {
    my $tx = shift;
    my $app = shift;
    weaken $tx;

    $tx->req->content->on(body => sub { 
        my $single  = shift;
        
        return unless $tx->req->url->path->contains('/upload');

        my $args = $tx->req->params->to_hash;
        my $file;
        if ( $args->{token} and $args->{name} and $args->{size} 
                and $args->{token} eq generateToken({ name => $args->{name}, size => $args->{size}}) ) {
                # 签名成功, 修改一些基本的信息
                my $filePath = getDstPath($args->{name});
                $tx->req->param(name => $filePath);             # 最终路径名
                $tx->req->param(path => $filePath . '.temp');   # 中间临时路径名
                createDir($filePath);
                $file = Asset::File->new(path => $tx->req->param('path'), cleanup => 0);  # 整个句柄
        }

        if (!$file) {
            app->log->debug("远程地址: ". $tx->remote_address . " 认证失败:". $args->{token});
            $tx->res->code(200);
            $tx->res->headers->content_type("application/json");
            $tx->res->body(encode_json({
                success => 0,
                message => 'Error: 签名认证失败',
            }));
            return $tx->resume;
        }

        return unless $tx->req->method eq 'POST' or $tx->req->method eq 'OPTIONS';
        $tx->req->max_message_size(0); # 让它可以上传无限大小

        my ($from, $to, $range_size);
        if ( $tx->req->headers->content_range 
                and $tx->req->headers->content_range  =~ m/bytes (\w+)-(\d+)\/(\d+)/) {
            ($from, $to, $range_size) = ($1, $2, $3);
            $from = 0 if $from eq 'null';
            my $size = $file->size || 0;
            if (!$range_size or $size != $from) {
                $tx->res->code(416);
                $tx->res->headers->content_type("application/json");
                $tx->res->body(encode_json({
                    success => 0,
                    message => 'Error: 请求范围错误',
                }));
                return $tx->resume;
            }
        }

        $single->unsubscribe('read')->on(read => sub {
            my ($single, $bytes) = @_;
            $file->add_chunk($bytes);

            if ($range_size  and $file->size and $file->size == $range_size) {
                my $name  = $tx->req->param('name');
                $file->move_to($name);
                $tx->req->param(path => $name); # 因为要进入后面的 ROUTE 所以, 需要让后面的程序在文件名移位置后能检查到大小
                app->log->debug("远程地址: ". $tx->remote_address ." 上传文件: $name 完成");
            }
        });
    });
};

get '/' => "index";
get '/bootstrap';

get '/tk' => sub { 
    my $self  = shift;
    my $name  = $self->param('name');
    my $size  = $self->param('size');
    my $token = generateToken({ name => $name, size => $size}); 

    my $success = 1;
    my $message = '';

    return $self->render(json => {
        token   => $token,
        server  => $UploadServer,
        success => $success,
        message => $message,
    }); 
};


# html5 文件上传和查询接口
# URI： /upload
# 参数：name（文件名，必填，如1040199_50.jpg）
#       token（Token，必填，如A1409681943_1557）
#       client（上传类型，必填，html5）
#       size（文件字节大小，必填，空文件为0，如1557）
# 头信息：Content-Range（必须传入的头信息，格式：bytes 开始字节-结束字节/总字节，如：Content-Range:bytes 0-1557/1557）
any [qw(POST OPTIONS GET)] =>  '/upload' => sub {
    my $self = shift;

    $self->res->headers->header('Access-Control-Allow-Headers' => 'Content-Range,Content-Type');
    $self->res->headers->header('Access-Control-Allow-Origin'  => $CrossOrigins);
    $self->res->headers->header('Access-Control-Allow-Methods' => 'POST, GET, OPTIONS');

    my $file = Asset::File->new(path => $self->param('path'));  # 整个句柄
    
    return $self->render(json => {
        start   => $file->size || 0,
        success => 1,
        message => '',
    });
};


# flash 上传接口
# URI： /fd
# 参数： token（Token，必填，如A1409681943_1557）
#        client（上传类型，必填，form）
# 方式：POST
post '/fd' => sub {
    my $self = shift;

    my $upload = $self->req->upload('FileData');
    my $name   = $upload->filename;
    my $size   = $upload->size;
    my $token  = $self->param("token");

    my $args = $self->req->params->to_hash;
    my $filePath;
    if ( $args->{token} and $args->{name} and $args->{size} 
        and $args->{token} eq generateToken({ name => $args->{name}, size => $args->{size}}) ) {
        $filePath = getDstPath($name);
        createDir($filePath);
    }

    my $success = 0;
    if ($filePath) {
        $success = 1;
        $upload->move_to($filePath);
        app->log->debug("远程地址: ". $self->tx->remote_address ." 上传文件: $filePath 完成");
    }

    return $self->render(json => {
        start   => $upload->size || 0, 
        success => $success,
        message => '',
    });
};

sub getDstPath {
    my ($pathName, $size) = shift;
    if ($size) {
        return catfile( $FileRepository, "${size}_$pathName" );
    }
    else {
        return catfile( $FileRepository, $pathName);
    }
}

sub check_signature {
    my ($signature, $prikey, $path) = @_;
    my $tmpSign   = lc md5_hex( "$path$prikey");

    if ( substr($tmpSign, 16) eq $signature ) {
        return 1
    }
}

sub generateToken {
    my $args = shift;
    $args->{size} ||= "0000";
    return if !$args->{name};
    my $key_file = md5_hex(encode_utf8($args->{name}))  . $args->{size};
     
    my $tmpSign   = lc md5_hex( $key_file. $TokenKey );
    return substr($tmpSign, 16) . "_" . $key_file
}

sub createDir {
    my $dest = shift;
    return if !$dest or -d $dest;

    my $dir  = File::Basename::dirname( $dest );
    if (! -e $dir ) {
        if (! File::Path::make_path( $dir ) || ! -d $dir ) {            
             my $e = $!;
             debugf("Failed to createdir %s: %s", $dir, $e);
        }
    }
}
app->start();

__DATA__

@@ crossdomain.xml
<?xml version="1.0" encoding="UTF-8"?>
<cross-domain-policy>
<allow-access-from domain="*"/>
</cross-domain-policy>

@@ index.html.ep
<!DOCTYPE html>
<html>
<head>
<title>New Style SWF/HTML5 Stream Uploading DEMO</title>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<link href="stream-v1.css" rel="stylesheet" type="text/css">
</head>
<body>
	<div id="i_select_files">
	</div>

	<div id="i_stream_files_queue">
	</div>
	<button onclick="javascript:_t.upload();">开始上传</button>|<button onclick="javascript:_t.stop();">停止上传</button>|<button onclick="javascript:_t.cancel();">取消</button>
	|<button onclick="javascript:_t.disable();">禁用文件选择</button>|<button onclick="javascript:_t.enable();">启用文件选择</button>
	<br>
	Messages:
	<div id="i_stream_message_container" class="stream-main-upload-box" style="overflow: auto;height:200px;">
	</div>
<br>


<script type="text/javascript" src="stream-v1.js"></script>
<script type="text/javascript">
/**
 * 配置文件（如果没有默认字样，说明默认值就是注释下的值）
 * 但是，on*（onSelect， onMaxSizeExceed...）等函数的默认行为
 * 是在ID为i_stream_message_container的页面元素中写日志
 */
	var config = {
		browseFileId : "i_select_files", /** 选择文件的ID, 默认: i_select_files */
		browseFileBtn : "<div>请选择文件</div>", /** 显示选择文件的样式, 默认: `<div>请选择文件</div>` */
		dragAndDropArea: "i_select_files", /** 拖拽上传区域，Id（字符类型"i_select_files"）或者DOM对象, 默认: `i_select_files` */
		dragAndDropTips: "<span>把文件(文件夹)拖拽到这里</span>", /** 拖拽提示, 默认: `<span>把文件(文件夹)拖拽到这里</span>` */
		filesQueueId : "i_stream_files_queue", /** 文件上传容器的ID, 默认: i_stream_files_queue */
		filesQueueHeight : 200, /** 文件上传容器的高度（px）, 默认: 450 */
		messagerId : "i_stream_message_container", /** 消息显示容器的ID, 默认: i_stream_message_container */
		multipleFiles: true /** 多个文件一起上传, 默认: false */
	};
	var _t = new Stream(config);
</script>
</body>

@@ stream-v1.css
@charset "utf-8";
body {
	color: #000;
	line-height: 166.6%;
	float: left;
	font-family: verdana;
	font-size: 12px;
}

ul,ol {
	list-style: none;
}

ul,ol,li,img {
	border: 0 none;
	margin: 0;
	padding: 0;
}

.stream-browse-files {
	overflow: hidden;
	position: relative;
}

.stream-browse-drag-files-area {
	border: 2px dashed #555;
	padding: 10px 0;
	border-radius: 7px;
	text-align: center;
	margin: 10px 0;
	cursor: pointer;
}

.stream-disable-browser {
	color: #909090;
}

.stream-files-scroll {
	height: 450px;
	overflow: auto;
}

.stream-cell-file {
	cursor: default;
	position: relative;
	zoom: 1;
	padding: 10px 20px 10px 35px;
	border-bottom-width: 1px;
	border-bottom-style: dotted;
	border-color: #ccc;
}

.stream-cell-file .stream-cell-infos:before,.stream-cell-file .stream-cell-infos:after {
	clear: both;
	content: ".";
	font-size: 0;
	display: block;
	height: 0;
	overflow: hidden;
	visibility: hidden;
}

.stream-cell-file .stream-file-name {
	width: 100%;
	overflow: hidden;
	text-overflow: ellipsis;
}

.stream-cell-file .stream-process {
	zoom: 1;
	overflow: hidden;
}

.stream-cell-file .stream-cancel {
	margin-right: 5px;
	float: right;
}

a {
	color: #158144;
}

.stream-cell-file .stream-process-bar {
	width: 300px;
}

.stream-cell-file .stream-process-bar,.stream-cell-file .stream-percent {
	float: left;
	margin-right: 10px;
}

.stream-cell-file .stream-process-bar {
	margin-top: 5px;
	width: 430px;
}

.stream-process-bar {
	position: relative;
	border: 1px solid #ccc;
	background: #fff;
	width: 55px;
	height: 10px;
	overflow: hidden;
}

.stream-process-bar span {
	position: absolute;
	left: 0;
	top: 0;
	height: 8px;
	border: 1px solid #fff;
	font-size: 0;
	background-position: 0 -149px;
	background-image: url(./bgx.png);
	background-repeat: repeat-x;
	background-color: #A5DD3D;
}

.stream-process-bar,.stream-process-bar span {
	-moz-box-sizing: border-box;
	-webkit-box-sizing: border-box;
	-khtml-box-sizing: border-box;
	box-sizing: border-box;
}

.stream-cell-file .stream-cell-infos {
	zoom: 1;
	color: #7D7D7D;
}

.stream-cell-file .stream-cell-infos .stream-cell-info {
	width: 170px;
}

.stream-cell-file .stream-cell-infos span {
	float: left;
	margin-right: 8px;
}

.stream-total-tips .stream-process-bar {
	width: 200px;
	margin-top: -1px;
}

.stream-process-bar, .stream-uploading-ico {
	-moz-box-align: center;
	display: inline-block;
	vertical-align: middle;
	zoom: 1;
}

.stream-total-tips {
	border: 1px solid #ccc;
	border-width: 1px 0 0;
	padding: 3px 5px 3px 25px;
	position: relative;
	zoom: 1;
	background-color: #FFFFE1;
	color: #565656;
}

.stream-main-upload-box {
	width: 610px;
	background-color: #FFFFFF;
	border-style: solid;
	border-width: 1px;
	border-color: #50A05B;
	clear: both;
	overflow: hidden;
}

.stream-uploading-ico {
	left: 11px;
	position: absolute;
	top: 11px;
	background: url("./upload.gif") no-repeat scroll 0 1px transparent !important;
	height: 18px;
	width: 18px;
}

.stream-disabled {
	cursor: not-allowed;
	pointer-events: none;
	opacity: .65;
	filter: alpha(opacity=65);
	-webkit-box-shadow: none;
	box-shadow: none;
}

@@ stream-v1.js (base64)
LyoqDQogKiBAbmFtZSBVcGxvYWRlci5qcw0KICogQGF1dGhvciBKaWFuZw0KICogQGNyZWF0ZQky
MDEyLTEyLTIwDQogKiBAdmVyc2lvbiAwLjENCiAqIEBkZXNjcmlwdGlvbglUaGUgQW5ub3VzZSBm
dW50aW9uIGZvciBIVE1MNS9GTEFTSC9GT1JNIHVwbG9hZCBtZXRob2QuIFRoZQ0KICogCWZ1bmN0
aW9uIHdpbGwgYXV0b2x5IHRvIGNob29zZSB0aGUgcHJvcGVydHkgbWV0aG9kIHRvIGFqdXN0IHRv
IGNsaWVudA0KICogIEJyb3dzd2VyLiBUaGlzIGpzIGZ1bmN0aW9uIG1haW5seSBib3Jyb3cgZnJv
bSB5b3VrdS5jb20ncyB1cGxvYWRlci5taW4uanMNCiAqICBhbmQgdHJ5IHRvIHJlLWNyZWF0ZSBp
dCBmb3IgZnVsbGZpdGluZyBteSByZXF1aXJlbWVudC4gDQogKiBAZXhhbXBsZQ0KICogCQkxLiBu
ZXcgU3RyZWFtKCk7DQogKiAJCTIuIHZhciBjZmcgPSB7DQogKiAJCQkJZXh0RmlsdGVycyA6IFsi
LnR4dCIsICIuZ3oiXSwNCiAqIAkJCQlmaWxlRmllbGROYW1lIDogIkZpbGVEYXRhIg0KICogCQkJ
fTsNCiAqIAkJICAgbmV3IFN0cmVhbShjZmcpOw0KICovIA0KKGZ1bmN0aW9uKCl7DQoJdmFyIFBy
b3ZpZGVyLCBhRmlsdGVycyA9IFtdLCBuSWRDb3VudCA9IDAsIGFPdGhlckJyb3dzZXJzID0gWyJN
YXh0aG9uIiwgIlNFIDIuWCIsICJRUUJyb3dzZXIiXSwNCgkJblplcm8gPSAwLCBzT25lU3BhY2Ug
PSAiICIsIHNMQnJhY2UgPSAieyIsIHNSQnJhY2UgPSAifSIsDQoJCWdhID0gLyh+LShcZCspLX4p
L2csIHJMQnJhY2UgPSAvXHtMQlJBQ0VcfS9nLCByUkJyYWNlID0gL1x7UkJSQUNFXH0vZywNCgkJ
ZWEgPSB7DQoJCQkiJiIgOiAiJmFtcDsiLA0KCQkJIjwiIDogIiZsdDsiLA0KCQkJIj4iIDogIiZn
dDsiLA0KCQkJJyInIDogIiZxdW90OyIsDQoJCQkiJyIgOiAiJiN4Mjc7IiwNCgkJCSIvIiA6ICIm
I3gyRjsiLA0KCQkJImAiIDogIiYjeDYwOyINCgkJfSwgcGEgPSBBcnJheS5pc0FycmF5ICYmIC9c
e1xzKlxbKD86bmF0aXZlIGNvZGV8ZnVuY3Rpb24pXF1ccypcfS9pLnRlc3QoQXJyYXkuaXNBcnJh
eSkNCgkJCT8gQXJyYXkuaXNBcnJheQ0KCQkJOiBmdW5jdGlvbihhKSB7cmV0dXJuICJhcnJheSIg
PT09IGZUb1N0cmluZyhhKX0sDQoJCXNTdHJlYW1NZXNzYWdlcklkID0gImlfc3RyZWFtX21lc3Nh
Z2VfY29udGFpbmVyIiwNCgkJc0NlbGxGaWxlVGVtcGxhdGUgPSAnPGIgY2xhc3M9InN0cmVhbS11
cGxvYWRpbmctaWNvIj48L2I+JyArDQoJCQkJCSc8ZGl2IGNsYXNzPSJzdHJlYW0tZmlsZS1uYW1l
Ij48c3Ryb25nPjwvc3Ryb25nPjwvZGl2PicgKw0KCQkJCQknPGRpdiBjbGFzcz0ic3RyZWFtLXBy
b2Nlc3MiPicgKw0KCQkJCQknCTxhIGNsYXNzPSJzdHJlYW0tY2FuY2VsIiBocmVmPSJqYXZhc2Ny
aXB0OnZvaWQoMCkiPlx1NTIyMFx1OTY2NDwvYT4nICsNCgkJCQkJJwk8c3BhbiBjbGFzcz0ic3Ry
ZWFtLXByb2Nlc3MtYmFyIj48c3BhbiBzdHlsZT0id2lkdGg6IDAlOyI+PC9zcGFuPjwvc3Bhbj4n
ICsNCgkJCQkJJwk8c3BhbiBjbGFzcz0ic3RyZWFtLXBlcmNlbnQiPjAlPC9zcGFuPicgKw0KCQkJ
CQknPC9kaXY+JyArDQoJCQkJCSc8ZGl2IGNsYXNzPSJzdHJlYW0tY2VsbC1pbmZvcyI+JyArDQoJ
CQkJCScJPHNwYW4gY2xhc3M9InN0cmVhbS1jZWxsLWluZm8iPlx1OTAxZlx1NWVhNlx1ZmYxYTxl
bSBjbGFzcz0ic3RyZWFtLXNwZWVkIj48L2VtPjwvc3Bhbj4nICsNCgkJCQkJJwk8c3BhbiBjbGFz
cz0ic3RyZWFtLWNlbGwtaW5mbyI+XHU1ZGYyXHU0ZTBhXHU0ZjIwXHVmZjFhPGVtIGNsYXNzPSJz
dHJlYW0tdXBsb2FkZWQiPjwvZW0+PC9zcGFuPicgKw0KCQkJCQknCTxzcGFuIGNsYXNzPSJzdHJl
YW0tY2VsbC1pbmZvIj5cdTUyNjlcdTRmNTlcdTY1ZjZcdTk1ZjRcdWZmMWE8ZW0gY2xhc3M9InN0
cmVhbS1yZW1haW4tdGltZSI+PC9lbT48L3NwYW4+JyArDQoJCQkJCSc8L2Rpdj4nLA0KCQlzVG90
YWxDb250YWluZXIgPSAnPGRpdiBpZD0iI3RvdGFsQ29udGFpbmVySWQjIiBjbGFzcz0ic3RyZWFt
LXRvdGFsLXRpcHMiPicgKw0KCQkJJwlcdTRlMGFcdTRmMjBcdTYwM2JcdThmZGJcdTVlYTZcdWZm
MWE8c3BhbiBjbGFzcz0ic3RyZWFtLXByb2Nlc3MtYmFyIj48c3BhbiBzdHlsZT0id2lkdGg6IDAl
OyI+PC9zcGFuPjwvc3Bhbj4nICsNCgkJCScJPHNwYW4gY2xhc3M9InN0cmVhbS1wZXJjZW50Ij4w
JTwvc3Bhbj5cdWZmMGNcdTVkZjJcdTRlMGFcdTRmMjA8c3Ryb25nIGNsYXNzPSJfc3RyZWFtLXRv
dGFsLXVwbG9hZGVkIj4mbmJzcDs8L3N0cm9uZz4nICsNCgkJCScJXHVmZjBjXHU2MDNiXHU2NTg3
XHU0ZWY2XHU1OTI3XHU1YzBmPHN0cm9uZyBjbGFzcz0iX3N0cmVhbS10b3RhbC1zaXplIj4mbmJz
cDs8L3N0cm9uZz4nICsNCgkJCSc8L2Rpdj4nLA0KCQlzRmlsZXNDb250YWluZXIJPSAnPGRpdiBj
bGFzcz0ic3RyZWFtLWZpbGVzLXNjcm9sbCIgc3R5bGU9ImhlaWdodDogI2ZpbGVzUXVldWVIZWln
aHQjcHg7Ij48dWwgaWQ9IiNmaWxlc0NvbnRhaW5lcklkIyI+PC91bD48L2Rpdj4nOw0KCQ0KCWZ1
bmN0aW9uIGZHZW5lcmF0ZUlkKHByZWZpeCkgew0KCQl2YXIgYiA9IChuZXcgRGF0ZSkuZ2V0VGlt
ZSgpICsgIl8wMXZfIiArICsrbklkQ291bnQ7DQoJCXJldHVybiBwcmVmaXggPyBwcmVmaXggKyAi
XyIgKyBiIDogYjsNCgl9DQoJZnVuY3Rpb24gZkdldFJhbmRvbSgpIHsNCgkJcmV0dXJuIChuZXcg
RGF0ZSkuZ2V0VGltZSgpLnRvU3RyaW5nKCkuc3Vic3RyaW5nKDgpOw0KCX0NCglmdW5jdGlvbiBm
RXh0ZW5kKGEsIGIpew0KCQl2YXIgYyA9IDIgPCBhcmd1bWVudHMubGVuZ3RoID8gW2FyZ3VtZW50
c1syXV0gOiBudWxsOw0KCQlyZXR1cm4gZnVuY3Rpb24oKXsNCgkJCXZhciBkID0gInN0cmluZyIg
PT09IHR5cGVvZiBhID8gYlthXSA6IGEsZT1jID8gW2FyZ3VtZW50c1swXV0uY29uY2F0KGMpIDog
YXJndW1lbnRzOw0KCQkJcmV0dXJuIGQuYXBwbHkoYnx8ZCwgZSk7DQoJCX07DQoJfQ0KCQ0KCWZ1
bmN0aW9uIGZBZGRFdmVudExpc3RlbmVyKGEsIGIsIGMpIHsNCgkJYS5hZGRFdmVudExpc3RlbmVy
ID8gYS5hZGRFdmVudExpc3RlbmVyKGIsIGMsICExKSA6IGEuYXR0YWNoRXZlbnQgPyBhDQoJCQkJ
LmF0dGFjaEV2ZW50KCJvbiIgKyBiLCBjKSA6IGFbIm9uIiArIGJdID0gYzsNCgl9DQoJDQoJZnVu
Y3Rpb24gZlJlbW92ZUV2ZW50TGlzdGVuZXIoYSwgYiwgYykgew0KCQlhLnJlbW92ZUV2ZW50TGlz
dGVuZXIgPyBhLnJlbW92ZUV2ZW50TGlzdGVuZXIoYiwgYywgITEpIDogYS5kZXRhY2hFdmVudA0K
CQkJCT8gYS5kZXRhY2hFdmVudCgib24iICsgYiwgYykNCgkJCQk6IGFbIm9uIiArIGJdID0gbnVs
bDsNCgl9DQoJDQoJZnVuY3Rpb24gZlRvU3RyaW5nKGEpIHsNCgkJdmFyIGIgPSB7DQoJCQkidW5k
ZWZpbmVkIiA6ICJ1bmRlZmluZWQiLA0KCQkJbnVtYmVyIDogIm51bWJlciIsDQoJCQkiYm9vbGVh
biIgOiAiYm9vbGVhbiIsDQoJCQlzdHJpbmcgOiAic3RyaW5nIiwNCgkJCSJbb2JqZWN0IEZ1bmN0
aW9uXSIgOiAiZnVuY3Rpb24iLA0KCQkJIltvYmplY3QgUmVnRXhwXSIgOiAicmVnZXhwIiwNCgkJ
CSJbb2JqZWN0IEFycmF5XSIgOiAiYXJyYXkiLA0KCQkJIltvYmplY3QgRGF0ZV0iIDogImRhdGUi
LA0KCQkJIltvYmplY3QgRXJyb3JdIiA6ICJlcnJvciINCgkJfTsNCgkJcmV0dXJuIGJbdHlwZW9m
IGFdIHx8IGJbT2JqZWN0LnByb3RvdHlwZS50b1N0cmluZy5jYWxsKGEpXSB8fCAoYSA/ICJvYmpl
Y3QiIDogIm51bGwiKTsNCgl9DQoJDQoJZnVuY3Rpb24gZkFkZFZhcnMoanNvbiwgdXJsLCBjKSB7
DQoJCXZhciBfYXJyYXkgPSBbXSwgX3NlcCA9ICImIiwgZiA9IGZ1bmN0aW9uKGpzb24sIGMpIHsN
CgkJCXZhciBlID0gdXJsID8gL1xbXF0kLy50ZXN0KHVybCkgPyB1cmwgOiB1cmwgKyAiWyIgKyBj
ICsgIl0iIDogYzsNCgkJCSJ1bmRlZmluZWQiICE9IGUgJiYgInVuZGVmaW5lZCIgIT0gYw0KCQkJ
CSYmIF9hcnJheS5wdXNoKCJvYmplY3QiID09PSB0eXBlb2YganNvbg0KCQkJCQkJCT8gZkFkZFZh
cnMoanNvbiwgZSwgITApDQoJCQkJCQkJOiAiW29iamVjdCBGdW5jdGlvbl0iID09PSBPYmplY3Qu
cHJvdG90eXBlLnRvU3RyaW5nLmNhbGwoanNvbikNCgkJCQkJCQkJPyBlbmNvZGVVUklDb21wb25l
bnQoZSkgKyAiPSIgKyBlbmNvZGVVUklDb21wb25lbnQoanNvbigpKQ0KCQkJCQkJCQk6IGVuY29k
ZVVSSUNvbXBvbmVudChlKSArICI9IiArIGVuY29kZVVSSUNvbXBvbmVudChqc29uKSkNCgkJfTsN
CgkJaWYgKCFjICYmIHVybCkNCgkJCV9zZXAgPSAvXD8vLnRlc3QodXJsKSA/IC9cPyQvLnRlc3Qo
dXJsKSA/ICIiIDogIiYiIDogIj8iLA0KCQkJX2FycmF5LnB1c2godXJsKSwNCgkJCV9hcnJheS5w
dXNoKGZBZGRWYXJzKGpzb24pKTsNCgkJZWxzZSBpZiAoIltvYmplY3QgQXJyYXldIiA9PT0gT2Jq
ZWN0LnByb3RvdHlwZS50b1N0cmluZy5jYWxsKGpzb24pDQoJCQkJJiYgInVuZGVmaW5lZCIgIT0g
dHlwZW9mIGpzb24pDQoJCQlmb3IgKHZhciBnID0gMCwgYyA9IGpzb24ubGVuZ3RoOyBnIDwgYzsg
KytnKQ0KCQkJCWYoanNvbltnXSwgZyk7DQoJCWVsc2UgaWYgKCJ1bmRlZmluZWQiICE9IHR5cGVv
ZiBqc29uICYmIG51bGwgIT09IGpzb24gJiYgIm9iamVjdCIgPT09IHR5cGVvZiBqc29uKQ0KCQkJ
Zm9yIChnIGluIGpzb24pDQoJCQkJZihqc29uW2ddLCBnKTsNCgkJZWxzZQ0KCQkJX2FycmF5LnB1
c2goZW5jb2RlVVJJQ29tcG9uZW50KHVybCkgKyAiPSIgKyBlbmNvZGVVUklDb21wb25lbnQoanNv
bikpOw0KCQlyZXR1cm4gX2FycmF5LmpvaW4oX3NlcCkucmVwbGFjZSgvXiYvLCAiIikucmVwbGFj
ZSgvJTIwL2csICIrIikNCgl9DQoJDQoJZnVuY3Rpb24gZk1lcmdlSnNvbihiYXNlLCBleHRlbmQp
IHsNCgkJdmFyIHJlc3VsdCA9IHt9Ow0KCQlmb3IgKHZhciBhdHRyIGluIGJhc2UpDQoJCQlyZXN1
bHRbYXR0cl0gPSBiYXNlW2F0dHJdOw0KCQlmb3IgKHZhciBhdHRyIGluIGV4dGVuZCkNCgkJCXJl
c3VsdFthdHRyXSA9IGV4dGVuZFthdHRyXTsNCgkJcmV0dXJuIHJlc3VsdDsNCgl9DQoJDQoJZnVu
Y3Rpb24gZkFkZENsYXNzKGVsZW1lbnQsIGtsYXNzKSB7DQoJCWZIYXNDbGFzcyhlbGVtZW50LCBr
bGFzcykgfHwgKGVsZW1lbnQuY2xhc3NOYW1lICs9ICIgIiArIGtsYXNzKTsNCgl9DQoJDQoJZnVu
Y3Rpb24gZkhhc0NsYXNzKGVsZW1lbnQsIGtsYXNzKSB7DQoJCXJldHVybiBSZWdFeHAoIihefCAp
IiArIGtsYXNzICsgIiggfCQpIikudGVzdChlbGVtZW50LmNsYXNzTmFtZSk7DQoJfQ0KCQ0KCWZ1
bmN0aW9uIGZSZW1vdmVDbGFzcyhlbGVtZW50LCBrbGFzcykgew0KCQllbGVtZW50LmNsYXNzTmFt
ZSA9IGVsZW1lbnQuY2xhc3NOYW1lLnJlcGxhY2UoUmVnRXhwKCIoXnwgKSIgKyBrbGFzcyArICIo
IHwkKSIpLCAiICIpDQoJCQkJLnJlcGxhY2UoL15ccyt8XHMrJC9nLCAiIik7DQoJfQ0KCQ0KCWZ1
bmN0aW9uIGZDb250YWlucyhjb250YWluZXIsIGtsYXNzKSB7DQoJCWlmICghY29udGFpbmVyKQ0K
CQkJcmV0dXJuIFtdOw0KCQlpZiAoY29udGFpbmVyLnF1ZXJ5U2VsZWN0b3JBbGwpDQoJCQlyZXR1
cm4gY29udGFpbmVyLnF1ZXJ5U2VsZWN0b3JBbGwoIi4iICsga2xhc3MpOw0KCQlmb3IgKHZhciBj
ID0gW10sIGVsZXMgPSBjb250YWluZXIuZ2V0RWxlbWVudHNCeVRhZ05hbWUoIioiKSwgZSA9IGVs
ZXMubGVuZ3RoLCBmID0gMDsgZiA8IGU7IGYrKykNCgkJCWZIYXNDbGFzcyhlbGVzW2ZdLCBrbGFz
cykgJiYgYy5wdXNoKGVsZXNbZl0pOw0KCQlyZXR1cm4gYzsNCgl9DQoJDQoJZnVuY3Rpb24gZkNy
ZWF0ZUNvbnRlbnRFbGUoY29udGVudCkgew0KCQl2YXIgYiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1l
bnQoImRpdiIpOw0KCQliLmlubmVySFRNTCA9IGNvbnRlbnQ7DQoJCWNvbnRlbnQgPSBiLmNoaWxk
Tm9kZXM7DQoJCXJldHVybiBjb250ZW50WzBdLnBhcmVudE5vZGUucmVtb3ZlQ2hpbGQoY29udGVu
dFswXSk7DQoJfQ0KCQ0KCWZ1bmN0aW9uIGZTaG93TWVzc2FnZShtc2csIHdhcm5pbmcpIHsNCgkJ
dmFyIG8gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChzU3RyZWFtTWVzc2FnZXJJZCk7DQoJCW8g
JiYgKG8uaW5uZXJIVE1MICs9ICI8YnI+IiArICghIXdhcm5pbmcgPyAoIjxzcGFuIHN0eWxlPSdj
b2xvcjpyZWQ7Jz4iICsgbXNnICsgIjwvc3Bhbj4iKTogbXNnKSk7DQoJfQ0KCQ0KCWZ1bmN0aW9u
IGZNZXNzYWdlKG1zZywgVmFyVmFscywgYywgZCkgew0KCQlmb3IgKHZhciBuTEluZGV4LCBuUklu
ZGV4LCBzZXBJbmRleCwgYXJnTmFtZSwgc2Vjb25kVmFyLCBzID0gW10sIF9hcmdOYW1lLCBsZW5n
dGggPSBtc2cubGVuZ3RoOzspIHsNCgkJCW5MSW5kZXggPSBtc2cubGFzdEluZGV4T2Yoc0xCcmFj
ZSwgbGVuZ3RoKTsNCgkJCWlmICgwID4gbkxJbmRleCkNCgkJCQlicmVhazsNCgkJCW5SSW5kZXgg
PSBtc2cuaW5kZXhPZihzUkJyYWNlLCBuTEluZGV4KTsNCgkJCWlmIChuTEluZGV4ICsgMSA+PSBu
UkluZGV4KQ0KCQkJCWJyZWFrOw0KCQkJYXJnTmFtZSA9IF9hcmdOYW1lID0gbXNnLnN1YnN0cmlu
ZyhuTEluZGV4ICsgMSwgblJJbmRleCk7DQoJCQlzZWNvbmRWYXIgPSBudWxsOw0KCQkJc2VwSW5k
ZXggPSBhcmdOYW1lLmluZGV4T2Yoc09uZVNwYWNlKTsNCgkJCS0xIDwgc2VwSW5kZXggJiYgKHNl
Y29uZFZhciA9IGFyZ05hbWUuc3Vic3RyaW5nKHNlcEluZGV4ICsgMSksIGFyZ05hbWUgPSBhcmdO
YW1lLnN1YnN0cmluZygwLCBzZXBJbmRleCkpOw0KCQkJc2VwSW5kZXggPSBWYXJWYWxzW2FyZ05h
bWVdOw0KCQkJYyAmJiAoc2VwSW5kZXggPSBjKGFyZ05hbWUsIHNlcEluZGV4LCBzZWNvbmRWYXIp
KTsNCgkJCSJ1bmRlZmluZWQiID09PSB0eXBlb2Ygc2VwSW5kZXggJiYgKHNlcEluZGV4ID0gIn4t
IiArIHMubGVuZ3RoICsgIi1+Iiwgcy5wdXNoKF9hcmdOYW1lKSk7DQoJCQltc2cgPSBtc2cuc3Vi
c3RyaW5nKDAsIG5MSW5kZXgpICsgc2VwSW5kZXggKyBtc2cuc3Vic3RyaW5nKG5SSW5kZXggKyAx
KTsNCgkJCWQgfHwgKGxlbmd0aCA9IG5MSW5kZXggLSAxKTsNCgkJfQ0KCQlyZXR1cm4gbXNnLnJl
cGxhY2UoZ2EsIGZ1bmN0aW9uKG1zZywgVmFyVmFscywgYykgew0KCQkJCQlyZXR1cm4gc0xCcmFj
ZSArIHNbcGFyc2VJbnQoYywgMTApXSArIHNSQnJhY2UNCgkJCQl9KS5yZXBsYWNlKHJMQnJhY2Us
IHNMQnJhY2UpLnJlcGxhY2UoclJCcmFjZSwgc1JCcmFjZSk7DQoJfQ0KCQ0KCWZ1bmN0aW9uIGZJ
c09iak9yRnVuKGEsIGIpIHsNCgkJdmFyIGMgPSB0eXBlb2YgYTsNCgkJcmV0dXJuIGEgJiYgKCJv
YmplY3QiID09PSBjIHx8ICFiICYmICgiZnVuY3Rpb24iID09PSBjIHx8ICJmdW5jdGlvbiIgPT09
IGZUb1N0cmluZyhhKSkpIHx8ICExOw0KCX0NCglmdW5jdGlvbiBmSXNOdW1iZXIodmFsKSB7DQoJ
CXJldHVybiAibnVtYmVyIiA9PT0gdHlwZW9mIHZhbCAmJiBpc0Zpbml0ZSh2YWwpOw0KCX0NCglm
dW5jdGlvbiBmSXNBcnJheSh2YWwpIHsNCgkJcmV0dXJuICJhcnJheSIgPT09IGZUb1N0cmluZyh2
YWwpOw0KCX0NCgkNCgkvKioNCgkgKiBUaGlzIGZ1bmN0aW9uIGlzIGZvciByZWdpc3RlcmluZyB0
aGUgZnVuY3Rpb24ocykgb24gaXRzIHByb3RvdHlwZS4NCgkgKiBAaG9zdFByb3RvdHlwZQl3aGlj
aCBpcyBpdHMgaG9zdCBwcm90b3R5cGUuDQoJICogQGZ1bnMJZnVuY3Rpb25zLCBzdWNoIGFze2Fh
OmZ1bmN0aW9uKCl7fSwgYmI6ZnVuY3Rpb24oKXt9fQ0KCSAqIEBmb3JzZVJlZwlib29sZWFuOiB3
aGVuIHRoZSBAaG9zdFByb3RvdHlwZSBkb24ndCBoYXZlIHRoZSBmdW5jdGlvbiwgdGhlbiByZWdp
c3RlciBpdC4NCgkgKiAJCXRydWU6IGRvIGl0LCBpZ25vcmUgdGhlIEBob3N0UHJvdG90eXBlIHdo
ZXRoZXIgaGFzIGl0Lg0KCSAqIAkJZmFsc2U6IHdoZW4gbm90IGhhdmUgaXQgc28gdGhhdCByZWdp
c3RlciBpdC4NCgkgKi8NCglmdW5jdGlvbiBmUmVnRnVucyhob3N0UHJvdG90eXBlLCBmdW5zLCBm
b3JzZVJlZywgZCkgew0KCQl2YXIgZSwgZiwgZzsNCgkJaWYgKCFob3N0UHJvdG90eXBlIHx8ICFm
dW5zKQ0KCQkJcmV0dXJuIGhvc3RQcm90b3R5cGUgfHwge307DQoJCWlmIChkKQ0KCQkJZm9yIChl
ID0gMCwgZyA9IGQubGVuZ3RoOyBlIDwgZzsgKytlKQ0KCQkJCWYgPSBkW2VdLCBPYmplY3QucHJv
dG90eXBlLmhhc093blByb3BlcnR5LmNhbGwoZnVucywgZikJJiYgKGZvcnNlUmVnIHx8ICEoZiBp
biBob3N0UHJvdG90eXBlKSkgJiYgKGhvc3RQcm90b3R5cGVbZl0gPSBmdW5zW2ZdKTsNCgkJZWxz
ZSB7DQoJCQlmb3IgKGYgaW4gZnVucykNCgkJCQlPYmplY3QucHJvdG90eXBlLmhhc093blByb3Bl
cnR5LmNhbGwoZnVucywgZikgJiYgKGZvcnNlUmVnIHx8ICEoZiBpbiBob3N0UHJvdG90eXBlKSkg
JiYgKGhvc3RQcm90b3R5cGVbZl0gPSBmdW5zW2ZdKTsNCgkJCSh7dmFsdWVPZiA6IDB9KS5wcm9w
ZXJ0eUlzRW51bWVyYWJsZSgidmFsdWVPZiIpCXx8IGZSZWdGdW5zKGhvc3RQcm90b3R5cGUsIGZ1
bnMsIGZvcnNlUmVnLCAiaGFzT3duUHJvcGVydHksaXNQcm90b3R5cGVPZixwcm9wZXJ0eUlzRW51
bWVyYWJsZSx0b1N0cmluZyx0b0xvY2FsZVN0cmluZyx2YWx1ZU9mIi5zcGxpdCgiLCIpKTsNCgkJ
fQ0KCQlyZXR1cm4gaG9zdFByb3RvdHlwZTsNCgl9DQoJDQoJZnVuY3Rpb24gZlJlZ0V2ZW50cygp
IHsNCgkJZlJlZ0Z1bnModGhpcy5jb25zdHJ1Y3Rvci5wcm90b3R5cGUsIHsNCgkJCQkJcHVibGlz
aCA6IGZ1bmN0aW9uKGEpIHsNCgkJCQkJCXRoaXMuX2V2dHNbYV0gfHwgKHRoaXMuX2V2dHNbYV0g
PSBudWxsKTsNCgkJCQkJfSwNCgkJCQkJb24gOiBmdW5jdGlvbihhLCBiLCBjKSB7DQoJCQkJCQl2
YXIgZCA9IHRoaXMuX2V2dHM7DQoJCQkJCQlkW2FdID0ge307DQoJCQkJCQlkW2FdLnR5cGUgPSBh
Ow0KCQkJCQkJdGhpcy5uYW1lICYmIChkW2FdLnR5cGUgPSB0aGlzLm5hbWUgKyAiOiIgKyBhKTsN
CgkJCQkJCWRbYV0uZm4gPSBmdW5jdGlvbigpIHsNCgkJCQkJCQliLmFwcGx5KGMsIGFyZ3VtZW50
cyk7DQoJCQkJCQl9Ow0KCQkJCQl9LA0KCQkJCQlhZnRlciA6IGZ1bmN0aW9uKGEsIGIsIGMpIHsN
CgkJCQkJCXRoaXMub24oYSwgYiwgYyk7DQoJCQkJCX0sDQoJCQkJCWZpcmUgOiBmdW5jdGlvbihh
KSB7DQoJCQkJCQl2YXIgYiA9IHRoaXMuX2V2dHNbYV07DQoJCQkJCQlpZiAoYikgew0KCQkJCQkJ
CXZhciBjID0ge3RhcmdldCA6IHRoaXMsCXR5cGUgOiBiLnR5cGV9LA0KCQkJCQkJCQlkID0gQXJy
YXkucHJvdG90eXBlLnNsaWNlLmNhbGwoYXJndW1lbnRzLCAxKTsNCgkJCQkJCQlpZiAoZklzT2Jq
T3JGdW4oZFswXSkpDQoJCQkJCQkJCWZvciAodmFyIGUgaW4gYykNCgkJCQkJCQkJCWRbMF1bZV0J
PyBkWzBdWyJfIiArIGVdID0gY1tlXSA6IGRbMF1bZV0gPSBjW2VdOw0KCQkJCQkJCWVsc2UNCgkJ
CQkJCQkJZFswXSA9IGM7DQoJCQkJCQkJImZ1bmN0aW9uIiA9PT0gZlRvU3RyaW5nKGIuZm4pICYm
IGIuZm4uYXBwbHkodGhpcywgZCk7DQoJCQkJCQl9DQoJCQkJCX0sDQoJCQkJCWRldGFjaCA6IGZ1
bmN0aW9uKGEpIHsNCgkJCQkJCWRlbGV0ZSB0aGlzLl9ldnRzW2FdOw0KCQkJCQl9DQoJCQkJfSwg
ITEpOw0KCQl0aGlzLl9ldnRzID0ge307DQoJfQ0KCQ0KCQ0KCWZ1bmN0aW9uIFBhcmVudChhcmdz
KSB7DQoJCWZSZWdFdmVudHMuY2FsbCh0aGlzKTsNCgkJdGhpcy5faXNBcHBseVN1cGVyQ2xhc3Mg
fHwgZlJlZ0Z1bnModGhpcy5jb25zdHJ1Y3Rvci5wcm90b3R5cGUsIFBhcmVudC5wcm90b3R5cGUs
ICExKTsNCgkJaWYgKGFyZ3MpIHsNCgkJCWZvciAodmFyIGZpZWxkIGluIGFyZ3MpDQoJCQkJdGhp
cy5zZXQoZmllbGQsIGFyZ3NbZmllbGRdKTsNCgkJfQ0KCQkiZnVuY3Rpb24iID09PSB0eXBlb2Yg
dGhpcy5pbml0aWFsaXplciAmJiB0aGlzLmluaXRpYWxpemVyLmFwcGx5KHRoaXMsIGFyZ3VtZW50
cyk7DQoJfQ0KCVBhcmVudC5wcm90b3R5cGUgPSB7DQoJCV9pc0FwcGx5U3VwZXJDbGFzcyA6ICEw
LA0KCQlpbml0aWFsaXplciA6IGZ1bmN0aW9uKCkgew0KCQl9LA0KCQlnZXQgOiBmdW5jdGlvbihr
ZXkpIHsNCgkJCXJldHVybiB0aGlzLmNvbmZpZ1trZXldOw0KCQl9LA0KCQlzZXQgOiBmdW5jdGlv
bihrZXksIHZhbCkgew0KCQkJdmFyIGM7DQoJCQlrZXkgJiYgInVuZGVmaW5lZCIgIT09IHR5cGVv
ZiB2YWwgJiYga2V5IGluIHRoaXMuY29uZmlnCSYmICh0aGlzLmNvbmZpZ1trZXldID0gdmFsLCBj
ID0ga2V5ICsgIkNoYW5nZSIsIHRoaXMuX2V2dCAmJiBjIGluIHRoaXMuX2V2dC5ldmVudHMgJiYg
dGhpcy5maXJlKGMpKTsNCgkJfQ0KCX07DQoJDQoJZnVuY3Rpb24gU1dGUmVmZXJlbmNlKGEsIGIs
IGMpIHsNCgkJZlJlZ0V2ZW50cy5jYWxsKHRoaXMpOw0KCQl2YXIgZCA9IHRoaXMuX2lkID0gZkdl
bmVyYXRlSWQoInVwbG9hZGVyLXN3ZiIpLCBjID0gYyB8fCB7fSwgZSA9ICgoYy52ZXJzaW9uIHx8
IHNGbGFzaFZlcnNpb24pICsgIiIpLnNwbGl0KCIuIiksDQoJCQllID0gU1dGUmVmZXJlbmNlLmlz
Rmxhc2hWZXJzaW9uQXRMZWFzdChwYXJzZUludChlWzBdLCAxMCksIHBhcnNlSW50KGVbMV0sIDEw
KSwgcGFyc2VJbnQoZVsyXSwgMTApKSwNCgkJCWYgPSBTV0ZSZWZlcmVuY2UuaXNGbGFzaFZlcnNp
b25BdExlYXN0KDgsIDAsIDApICYmICFlICYmIGMudXNlRXhwcmVzc0luc3RhbGwsDQoJCQlnID0g
ZiA/IHNGbGFzaERvd25sb2FkIDogYiwgDQoJCQliID0gIjxvYmplY3QgIiwgaCA9ICImU1dGSWQ9
IiArIGQgKyAiJmNhbGxiYWNrPSIgKyBzRmxhc2hFdmVudEhhbmRsZXIgKyAiJmFsbG93ZWREb21h
aW49IiArIGRvY3VtZW50LmxvY2F0aW9uLmhvc3RuYW1lOw0KCQlTV0ZSZWZlcmVuY2UuX2luc3Rh
bmNlc1tkXSA9IHRoaXM7DQoJCWlmIChhICYmIChlIHx8IGYpICYmIGcpIHsNCgkJCWIgKz0gJ2lk
PSInICsgZCArICciICc7DQoJCQliID0gQnJvd3Nlci5pZSA/IGIgKyAoJ2NsYXNzaWQ9IicgKyBz
SUVGbGFzaENsYXNzSWQgKyAnIiAnKSA6IGINCgkJCQkJKyAoJ3R5cGU9IicgKyBzU2hvY2t3YXZl
Rmxhc2ggKyAnIiBkYXRhPSInICsgZyArICciICcpOw0KCQkJYiArPSAnd2lkdGg9IjEwMCUiIGhl
aWdodD0iMTAwJSI+JzsNCgkJCUJyb3dzZXIuaWUgJiYgKGIgKz0gJzxwYXJhbSBuYW1lPSJtb3Zp
ZSIgdmFsdWU9IicgKyBnICsgJyIvPicpOw0KCQkJZm9yICh2YXIgaiBpbiBjLmZpeGVkQXR0cmli
dXRlcykNCgkJCQlvYS5oYXNPd25Qcm9wZXJ0eShqKQ0KCQkJCQkJJiYgKGIgKz0gJzxwYXJhbSBu
YW1lPSInICsgaiArICciIHZhbHVlPSInICsgYy5maXhlZEF0dHJpYnV0ZXNbal0gKyAnIi8+Jyk7
DQoJCQlmb3IgKHZhciBzIGluIGMuZmxhc2hWYXJzKQ0KCQkJCWogPSBjLmZsYXNoVmFyc1tzXSwg
InN0cmluZyIgPT09IHR5cGVvZiBqDQoJCQkJCQkmJiAoaCArPSAiJiIgKyBzICsgIj0iICsgZW5j
b2RlVVJJQ29tcG9uZW50KGopKTsNCgkJCWggJiYgKGIgKz0gJzxwYXJhbSBuYW1lPSJmbGFzaFZh
cnMiIHZhbHVlPSInICsgaCArICciLz4nKTsNCgkJCWEuaW5uZXJIVE1MID0gYiArICI8L29iamVj
dD4iOw0KCQkJdGhpcy5zd2YgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChkKTsNCgkJfSBlbHNl
DQoJCQl0aGlzLnB1Ymxpc2goIndyb25nZmxhc2h2ZXJzaW9uIiwge2ZpcmVPbmNlIDogITB9KSwg
dGhpcy5maXJlKCJ3cm9uZ2ZsYXNodmVyc2lvbiIsIHt0eXBlIDogIndyb25nZmxhc2h2ZXJzaW9u
In0pOw0KCX0NCgkNCglTV0ZSZWZlcmVuY2UuZ2V0Rmxhc2hWZXJzaW9uID0gZnVuY3Rpb24oKSB7
DQoJCXJldHVybiAiIiArIEJyb3dzZXIuZmxhc2hNYWpvciArICIuIiArICgiIiArIEJyb3dzZXIu
Zmxhc2hNaW5vcikgKyAiLiIgKyAoIiIgKyBCcm93c2VyLmZsYXNoUmV2KTsNCgl9Ow0KCVNXRlJl
ZmVyZW5jZS5pc0ZsYXNoVmVyc2lvbkF0TGVhc3QgPSBmdW5jdGlvbihhLCBiLCBjKSB7cmV0dXJu
IHRydWU7DQoJCS8qdmFyIGQgPSBwYXJzZUludChCcm93c2VyLmZsYXNoTWFqb3IsIDEwKSwgZSA9
IHBhcnNlSW50KEJyb3dzZXIuZmxhc2hNaW5vciwgMTApLCBmID0gcGFyc2VJbnQoDQoJCQkJQnJv
d3Nlci5mbGFzaFJldiwgMTApLCBhID0gcGFyc2VJbnQoYSB8fCAwLCAxMCksIGIgPSBwYXJzZUlu
dChiIHx8IDAsDQoJCQkJMTApLCBjID0gcGFyc2VJbnQoYyB8fCAwLCAxMCk7DQoJCXJldHVybiBh
ID09PSBkID8gYiA9PT0gZSA/IGMgPD0gZiA6IGIgPCBlIDogYSA8IGQ7Ki8NCgl9Ow0KCVNXRlJl
ZmVyZW5jZS5faW5zdGFuY2VzID0gU1dGUmVmZXJlbmNlLl9pbnN0YW5jZXMgfHwge307DQoJU1dG
UmVmZXJlbmNlLmV2ZW50SGFuZGxlciA9IGZ1bmN0aW9uKGEsIGIpIHtTV0ZSZWZlcmVuY2UuX2lu
c3RhbmNlc1thXS5fZXZlbnRIYW5kbGVyKGIpO307DQoJU1dGUmVmZXJlbmNlLnByb3RvdHlwZSA9
IHsNCgkJaW5pdGlhbGl6ZXIgOiBmdW5jdGlvbigpIHt9LA0KCQlfZXZlbnRIYW5kbGVyIDogZnVu
Y3Rpb24oYSkgew0KCQkJInN3ZlJlYWR5IiA9PT0gYS50eXBlID8gKHRoaXMucHVibGlzaCgic3dm
UmVhZHkiLCB7ZmlyZU9uY2UgOiAhMH0pLCB0aGlzLmZpcmUoInN3ZlJlYWR5IiwgYSkpDQoJCQkJ
CQkJCTogImxvZyIgIT09IGEudHlwZSAmJiB0aGlzLmZpcmUoYS50eXBlLCBhKTsNCgkJfSwNCgkJ
Y2FsbFNXRiA6IGZ1bmN0aW9uKGEsIGIpIHsNCgkJCWIgfHwgKGIgPSBbXSk7DQoJCQlyZXR1cm4g
dGhpcy5zd2ZbYV0gPyB0aGlzLnN3ZlthXS5hcHBseSh0aGlzLnN3ZiwgYikgOiBudWxsOw0KCQl9
LA0KCQl0b1N0cmluZyA6IGZ1bmN0aW9uKCkge3JldHVybiAiU1dGICIgKyB0aGlzLl9pZDt9DQoJ
fTsNCglTV0ZSZWZlcmVuY2UucHJvdG90eXBlLmNvbnN0cnVjdG9yID0gU1dGUmVmZXJlbmNlOw0K
CQ0KCWZ1bmN0aW9uIFNXRlByb3ZpZGVyKGEpIHsNCgkJdGhpcy5zd2ZDb250YWluZXJJZCA9IGZH
ZW5lcmF0ZUlkKCJ1cGxvYWRlciIpOw0KCQl0aGlzLnF1ZXVlID0gdGhpcy5zd2ZSZWZlcmVuY2Ug
PSBudWxsOw0KCQl0aGlzLmJ1dHRvblN0YXRlID0gInVwIjsNCgkJdGhpcy5jb25maWcgPSB7DQoJ
CQllbmFibGVkIDogITAsDQoJCQltdWx0aXBsZUZpbGVzIDogITAsDQoJCQlidXR0b25DbGFzc05h
bWVzIDogew0KCQkJCWhvdmVyIDogInVwbG9hZGVyLWJ1dHRvbi1ob3ZlciIsDQoJCQkJYWN0aXZl
IDogInVwbG9hZGVyLWJ1dHRvbi1hY3RpdmUiLA0KCQkJCWRpc2FibGVkIDogInVwbG9hZGVyLWJ1
dHRvbi1kaXNhYmxlZCIsDQoJCQkJZm9jdXMgOiAidXBsb2FkZXItYnV0dG9uLXNlbGVjdGVkIg0K
CQkJfSwNCgkJCWNvbnRhaW5lckNsYXNzTmFtZXMgOiB7aG92ZXIgOiAidXBob3RCZyJ9LA0KCQkJ
ZmlsZUZpbHRlcnMgOiBhRmlsdGVycywNCgkJCWZpbGVGaWVsZE5hbWUgOiAiRmlsZURhdGEiLA0K
CQkJc2ltTGltaXQgOiAxLA0KCQkJcmV0cnlDb3VudCA6IDMsDQoJCQlwb3N0VmFyc1BlckZpbGUg
OiB7fSwNCgkJCXN3ZlVSTCA6ICIvRmxhc2hVcGxvYWRlci5zd2YiLA0KCQkJdXBsb2FkVVJMIDog
Ii9mZCINCgkJfTsNCgkJUGFyZW50LmFwcGx5KHRoaXMsIGFyZ3VtZW50cyk7DQoJfQ0KCVNXRlBy
b3ZpZGVyLnByb3RvdHlwZSA9IHsNCgkJY29uc3RydWN0b3IgOiBTV0ZQcm92aWRlciwNCgkJbmFt
ZSA6ICJ1cGxvYWRlciIsDQoJCWJ1dHRvblN0YXRlIDogInVwIiwNCgkJc3dmQ29udGFpbmVySWQg
OiBudWxsLA0KCQlzd2ZSZWZlcmVuY2UgOiBudWxsLA0KCQlxdWV1ZSA6IG51bGwsDQoJCWluaXRp
YWxpemVyIDogZnVuY3Rpb24oKSB7DQoJCQl0aGlzLnB1Ymxpc2goImZpbGVzZWxlY3QiKTsNCgkJ
CXRoaXMucHVibGlzaCgidXBsb2Fkc3RhcnQiKTsNCgkJCXRoaXMucHVibGlzaCgiZmlsZXVwbG9h
ZHN0YXJ0Iik7DQoJCQl0aGlzLnB1Ymxpc2goInVwbG9hZHByb2dyZXNzIik7DQoJCQl0aGlzLnB1
Ymxpc2goInRvdGFsdXBsb2FkcHJvZ3Jlc3MiKTsNCgkJCXRoaXMucHVibGlzaCgidXBsb2FkY29t
cGxldGUiKTsNCgkJCXRoaXMucHVibGlzaCgiYWxsdXBsb2Fkc2NvbXBsZXRlIik7DQoJCQl0aGlz
LnB1Ymxpc2goInVwbG9hZGVycm9yIik7DQoJCQl0aGlzLnB1Ymxpc2goIm1vdXNlZW50ZXIiKTsN
CgkJCXRoaXMucHVibGlzaCgibW91c2VsZWF2ZSIpOw0KCQkJdGhpcy5wdWJsaXNoKCJtb3VzZWRv
d24iKTsNCgkJCXRoaXMucHVibGlzaCgibW91c2V1cCIpOw0KCQkJdGhpcy5wdWJsaXNoKCJjbGlj
ayIpOw0KCQl9LA0KCQlyZW5kZXIgOiBmdW5jdGlvbihhKSB7DQoJCQlhICYmICh0aGlzLnJlbmRl
clVJKGEpLCB0aGlzLmJpbmRVSSgpKTsNCgkJfSwNCgkJcmVuZGVyVUkgOiBmdW5jdGlvbihhKSB7
DQoJCQl0aGlzLmNvbnRlbnRCb3ggPSBhOw0KCQkJdGhpcy5jb250ZW50Qm94LnN0eWxlLnBvc2l0
aW9uID0gInJlbGF0aXZlIjsNCgkJCXZhciBiID0gZkNyZWF0ZUNvbnRlbnRFbGUoIjxkaXYgaWQ9
JyIgKyB0aGlzLnN3ZkNvbnRhaW5lcklkICsgIicgc3R5bGU9J3Bvc2l0aW9uOmFic29sdXRlO3Rv
cDowcHg7IGxlZnQ6IDBweDsgbWFyZ2luOiAwOyBwYWRkaW5nOiAwOyBib3JkZXI6IDA7IHdpZHRo
OjEwMCU7IGhlaWdodDoxMDAlJz48L2Rpdj4iKTsNCgkJCWIuc3R5bGUud2lkdGggPSBhLm9mZnNl
dFdpZHRoICsgInB4IjsNCgkJCWIuc3R5bGUuaGVpZ2h0ID0gYS5vZmZzZXRIZWlnaHQgKyAicHgi
Ow0KCQkJdGhpcy5jb250ZW50Qm94LmFwcGVuZENoaWxkKGIpOw0KCQkJdGhpcy5zd2ZSZWZlcmVu
Y2UgPSBuZXcgU1dGUmVmZXJlbmNlKGIsIHRoaXMuZ2V0KCJzd2ZVUkwiKSwgew0KCQkJCQkJdmVy
c2lvbiA6ICIxMC4wLjQ1IiwNCgkJCQkJCWZpeGVkQXR0cmlidXRlcyA6IHsNCgkJCQkJCQl3bW9k
ZSA6ICJ0cmFuc3BhcmVudCIsDQoJCQkJCQkJYWxsb3dTY3JpcHRBY2Nlc3MgOiAiYWx3YXlzIiwN
CgkJCQkJCQlhbGxvd05ldHdvcmtpbmcgOiAiYWxsIiwNCgkJCQkJCQlzY2FsZSA6ICJub3NjYWxl
Ig0KCQkJCQkJfQ0KCQkJCQl9KTsNCgkJfSwNCgkJYmluZFVJIDogZnVuY3Rpb24oKSB7DQoJCQl0
aGlzLnN3ZlJlZmVyZW5jZS5vbigic3dmUmVhZHkiLCBmdW5jdGlvbigpIHsNCgkJCQl0aGlzLnNl
dE11bHRpcGxlRmlsZXMoKTsNCgkJCQl0aGlzLnNldEZpbGVGaWx0ZXJzKCk7DQoJCQkJdGhpcy50
cmlnZ2VyRW5hYmxlZCgpOw0KCQkJCXRoaXMuYWZ0ZXIoIm11bHRpcGxlRmlsZXNDaGFuZ2UiLCB0
aGlzLnNldE11bHRpcGxlRmlsZXMsIHRoaXMpOw0KCQkJCXRoaXMuYWZ0ZXIoImZpbGVGaWx0ZXJz
Q2hhbmdlIiwgdGhpcy5zZXRGaWxlRmlsdGVycywgdGhpcyk7DQoJCQkJdGhpcy5hZnRlcigiZW5h
YmxlZENoYW5nZSIsIHRoaXMudHJpZ2dlckVuYWJsZWQsIHRoaXMpOw0KCQkJfSwgdGhpcyk7DQoJ
CQl0aGlzLnN3ZlJlZmVyZW5jZS5vbigiZmlsZXNlbGVjdCIsIHRoaXMudXBkYXRlRmlsZUxpc3Qs
IHRoaXMpOw0KCQkJdGhpcy5zd2ZSZWZlcmVuY2Uub24oIm1vdXNlZW50ZXIiLCBmdW5jdGlvbigp
IHt0aGlzLnNldENvbnRhaW5lckNsYXNzKCJob3ZlciIsICEwKTt9LCB0aGlzKTsNCgkJCXRoaXMu
c3dmUmVmZXJlbmNlLm9uKCJtb3VzZWxlYXZlIiwgZnVuY3Rpb24oKSB7dGhpcy5zZXRDb250YWlu
ZXJDbGFzcygiaG92ZXIiLCAhMSk7fSwgdGhpcyk7DQoJCX0sDQoJCXNldENvbnRhaW5lckNsYXNz
IDogZnVuY3Rpb24oYSwgYikgew0KCQkJYiA/IGZBZGRDbGFzcyh0aGlzLmNvbnRlbnRCb3gsIHRo
aXMuZ2V0KCJjb250YWluZXJDbGFzc05hbWVzIilbYV0pIDogZlJlbW92ZUNsYXNzKA0KCQkJCQl0
aGlzLmNvbnRlbnRCb3gsIHRoaXMuZ2V0KCJjb250YWluZXJDbGFzc05hbWVzIilbYV0pOw0KCQl9
LA0KCQlzZXRGaWxlRmlsdGVycyA6IGZ1bmN0aW9uKCkgew0KCQkJdGhpcy5zd2ZSZWZlcmVuY2Ug
JiYgMCA8IHRoaXMuZ2V0KCJmaWxlRmlsdGVycyIpLmxlbmd0aA0KCQkJCQkmJiB0aGlzLnN3ZlJl
ZmVyZW5jZS5jYWxsU1dGKCJzZXRGaWxlRmlsdGVycyIsIFt0aGlzLmdldCgiZmlsZUZpbHRlcnMi
KV0pOw0KCQl9LA0KCQlzZXRNdWx0aXBsZUZpbGVzIDogZnVuY3Rpb24oKSB7DQoJCQl0aGlzLnN3
ZlJlZmVyZW5jZSAmJiB0aGlzLnN3ZlJlZmVyZW5jZS5jYWxsU1dGKCJzZXRBbGxvd011bHRpcGxl
RmlsZXMiLCBbdGhpcy5nZXQoIm11bHRpcGxlRmlsZXMiKV0pOw0KCQl9LA0KCQl0cmlnZ2VyRW5h
YmxlZCA6IGZ1bmN0aW9uKCkgew0KCQkJdGhpcy5nZXQoImVuYWJsZWQiKQ0KCQkJCQk/ICh0aGlz
LnN3ZlJlZmVyZW5jZS5jYWxsU1dGKCJlbmFibGUiKSwgdGhpcy5zd2ZSZWZlcmVuY2Uuc3dmLnNl
dEF0dHJpYnV0ZSgiYXJpYS1kaXNhYmxlZCIsICJmYWxzZSIpKQ0KCQkJCQk6ICh0aGlzLnN3ZlJl
ZmVyZW5jZS5jYWxsU1dGKCJkaXNhYmxlIiksIHRoaXMuc3dmUmVmZXJlbmNlLnN3Zi5zZXRBdHRy
aWJ1dGUoImFyaWEtZGlzYWJsZWQiLCAidHJ1ZSIpKQ0KCQl9LA0KCQl1cGRhdGVGaWxlTGlzdCA6
IGZ1bmN0aW9uKGEpIHsNCgkJCXRoaXMuc3dmUmVmZXJlbmNlLnN3Zi5mb2N1cygpOw0KCQkJZm9y
ICh2YXIgYSA9IGEuZmlsZUxpc3QsIGIgPSBbXSwgYyA9IHRoaXMuc3dmUmVmZXJlbmNlLCBkID0g
MDsgZCA8IGEubGVuZ3RoOyBkKyspIHsNCgkJCQl2YXIgZSA9IHt9Ow0KCQkJCWUuaWQgPSBhW2Rd
LmZpbGVJZDsNCgkJCQllLm5hbWUgPSBhW2RdLmZpbGVSZWZlcmVuY2UubmFtZTsNCgkJCQllLnNp
emUgPSBhW2RdLmZpbGVSZWZlcmVuY2Uuc2l6ZTsNCgkJCQllLnR5cGUgPSBhW2RdLmZpbGVSZWZl
cmVuY2UudHlwZTsNCgkJCQllLmRhdGVDcmVhdGVkID0gYVtkXS5maWxlUmVmZXJlbmNlLmNyZWF0
aW9uRGF0ZTsNCgkJCQllLmRhdGVNb2RpZmllZCA9IGFbZF0uZmlsZVJlZmVyZW5jZS5tb2RpZmlj
YXRpb25EYXRlOw0KCQkJCWUudXBsb2FkZXIgPSBjOw0KCQkJCWIucHVzaChuZXcgU1dGVXBsb2Fk
ZXIoZSkpOw0KCQkJfQ0KCQkJMCA8IGIubGVuZ3RoICYmIHRoaXMuZmlyZSgiZmlsZXNlbGVjdCIs
IHtmaWxlTGlzdCA6IGJ9KTsNCgkJfSwNCgkJdXBsb2FkRXZlbnRIYW5kbGVyIDogZnVuY3Rpb24o
YSkgew0KCQkJc3dpdGNoIChhLnR5cGUpIHsNCgkJCQljYXNlICJleGVjdXRvcjp1cGxvYWRzdGFy
dCIgOg0KCQkJCQl0aGlzLmZpcmUoImZpbGV1cGxvYWRzdGFydCIsIGEpOw0KCQkJCQlicmVhazsN
CgkJCQljYXNlICJleGVjdXRvcjp1cGxvYWRwcm9ncmVzcyIgOg0KCQkJCQl0aGlzLmZpcmUoInVw
bG9hZHByb2dyZXNzIiwgYSk7DQoJCQkJCWJyZWFrOw0KCQkJCWNhc2UgInVwbG9hZGVycXVldWU6
dG90YWx1cGxvYWRwcm9ncmVzcyIgOg0KCQkJCQl0aGlzLmZpcmUoInRvdGFsdXBsb2FkcHJvZ3Jl
c3MiLCBhKTsNCgkJCQkJYnJlYWs7DQoJCQkJY2FzZSAiZXhlY3V0b3I6dXBsb2FkY29tcGxldGUi
IDoNCgkJCQkJdGhpcy5maXJlKCJ1cGxvYWRjb21wbGV0ZSIsIGEpOw0KCQkJCQlicmVhazsNCgkJ
CQljYXNlICJ1cGxvYWRlcnF1ZXVlOmFsbHVwbG9hZHNjb21wbGV0ZSIgOg0KCQkJCQl0aGlzLnF1
ZXVlID0gbnVsbDsNCgkJCQkJdGhpcy5maXJlKCJhbGx1cGxvYWRzY29tcGxldGUiLCBhKTsNCgkJ
CQkJYnJlYWs7DQoJCQkJY2FzZSAiZXhlY3V0b3I6dXBsb2FkZXJyb3IiIDoNCgkJCQljYXNlICJ1
cGxvYWRlcnF1ZXVlOnVwbG9hZGVycm9yIiA6DQoJCQkJCXRoaXMuZmlyZSgidXBsb2FkZXJyb3Ii
LCBhKTsNCgkJCQkJYnJlYWs7DQoJCQkJY2FzZSAiZXhlY3V0b3I6dXBsb2FkY2FuY2VsIiA6DQoJ
CQkJY2FzZSAidXBsb2FkZXJxdWV1ZTp1cGxvYWRjYW5jZWwiIDoNCgkJCQkJdGhpcy5maXJlKCJ1
cGxvYWRjYW5jZWwiLCBhKTsNCgkJCX0NCgkJfSwNCgkJdXBsb2FkIDogZnVuY3Rpb24odXBsb2Fk
ZXIsIHVybCwgcG9zdFZhcnMpIHsNCgkJCXZhciB1cmwgPSB1cmwgfHwgdGhpcy5nZXQoInVwbG9h
ZFVSTCIpLCBwb3N0VmFycyA9IGZNZXJnZUpzb24ocG9zdFZhcnMsIHRoaXMuZ2V0KCJwb3N0VmFy
c1BlckZpbGUiKSksIGlkID0gdXBsb2FkZXIuaWQsDQoJCQkJcG9zdFZhcnMgPSBwb3N0VmFycy5o
YXNPd25Qcm9wZXJ0eShpZCkgPyBwb3N0VmFyc1tpZF0gOiBwb3N0VmFyczsNCgkJCXVwbG9hZGVy
IGluc3RhbmNlb2YgU1dGVXBsb2FkZXINCgkJCQkJJiYgKHVwbG9hZGVyLm9uKCJ1cGxvYWRzdGFy
dCIsIHRoaXMudXBsb2FkRXZlbnRIYW5kbGVyLCB0aGlzKSwNCgkJCQkJCXVwbG9hZGVyLm9uKCJ1
cGxvYWRwcm9ncmVzcyIsIHRoaXMudXBsb2FkRXZlbnRIYW5kbGVyLCB0aGlzKSwNCgkJCQkJCXVw
bG9hZGVyLm9uKCJ1cGxvYWRjb21wbGV0ZSIsIHRoaXMudXBsb2FkRXZlbnRIYW5kbGVyLCB0aGlz
KSwNCgkJCQkJCXVwbG9hZGVyLm9uKCJ1cGxvYWRlcnJvciIsIHRoaXMudXBsb2FkRXZlbnRIYW5k
bGVyLCB0aGlzKSwNCgkJCQkJCXVwbG9hZGVyLm9uKCJ1cGxvYWRjYW5jZWwiLCB0aGlzLnVwbG9h
ZEV2ZW50SGFuZGxlciwgdGhpcyksDQoJCQkJCQl1cGxvYWRlci5zdGFydFVwbG9hZCh1cmwsIHBv
c3RWYXJzLCB0aGlzLmdldCgiZmlsZUZpZWxkTmFtZSIpKSk7DQoJCX0NCgl9Ow0KCQ0KCWZ1bmN0
aW9uIFNXRlVwbG9hZGVyKGEpIHsNCgkJdGhpcy5ieXRlc1NwZWVkID0gdGhpcy5ieXRlc1ByZXZM
b2FkZWQgPSAwOw0KCQl0aGlzLmJ5dGVzU3BlZWRzID0gW107DQoJCXRoaXMucHJlVGltZSA9IHRo
aXMucmVtYWluVGltZSA9IDA7DQoJCXRoaXMuY29uZmlnID0gew0KCQkJaWQgOiAiIiwNCgkJCW5h
bWUgOiAiIiwNCgkJCXNpemUgOiAiIiwNCgkJCXR5cGUgOiAiIiwNCgkJCWRhdGVDcmVhdGVkIDog
IiIsDQoJCQlkYXRlTW9kaWZpZWQgOiAiIiwNCgkJCXVwbG9hZGVyIDogIiINCgkJfTsNCgkJUGFy
ZW50LmFwcGx5KHRoaXMsIGFyZ3VtZW50cyk7DQoJfQkNCglTV0ZVcGxvYWRlci5wcm90b3R5cGUg
PSB7DQoJCWNvbnN0cnVjdG9yIDogU1dGVXBsb2FkZXIsDQoJCW5hbWUgOiAiZXhlY3V0b3IiLA0K
CQlpbml0aWFsaXplciA6IGZ1bmN0aW9uKCkgew0KCQkJdGhpcy5pZCA9IGZHZW5lcmF0ZUlkKCJm
aWxlIik7DQoJCX0sDQoJCXN3ZkV2ZW50SGFuZGxlciA6IGZ1bmN0aW9uKGEpIHsNCgkJCWlmIChh
LmlkID09PSB0aGlzLmdldCgiaWQiKSkNCgkJCQlzd2l0Y2ggKGEudHlwZSkgew0KCQkJCQljYXNl
ICJ1cGxvYWRzdGFydCIgOg0KCQkJCQkJdGhpcy5maXJlKCJ1cGxvYWRzdGFydCIsIHt1cGxvYWRl
ciA6IHRoaXMuZ2V0KCJ1cGxvYWRlciIpfSk7DQoJCQkJCQlicmVhazsNCgkJCQkJY2FzZSAidXBs
b2FkcHJvZ3Jlc3MiIDoNCgkJCQkJCXZhciBiID0gKG5ldyBEYXRlKS5nZXRUaW1lKCksIGMgPSAo
YiAtIHRoaXMucHJlVGltZSkgLyAxRTMsIGQgPSAwOw0KCQkJCQkJaWYgKDEgPD0gYyB8fCAwID09
IHRoaXMuYnl0ZXNQcmV2TG9hZGVkKSB7DQoJCQkJCQkJdGhpcy5ieXRlc1NwZWVkID0gTWF0aC5y
b3VuZCgoYS5ieXRlc0xvYWRlZCAtIHRoaXMuYnl0ZXNQcmV2TG9hZGVkKSAvIGMpOw0KCQkJCQkJ
CXRoaXMuYnl0ZXNQcmV2TG9hZGVkID0gYS5ieXRlc0xvYWRlZDsNCgkJCQkJCQl0aGlzLnByZVRp
bWUgPSBiOw0KCQkJCQkJCTUgPCB0aGlzLmJ5dGVzU3BlZWRzLmxlbmd0aCAmJiB0aGlzLmJ5dGVz
U3BlZWRzLnNoaWZ0KCk7DQoJCQkJCQkJdGhpcy5ieXRlc1NwZWVkcy5wdXNoKHRoaXMuYnl0ZXNT
cGVlZCk7DQoJCQkJCQkJZm9yIChiID0gMDsgYiA8IHRoaXMuYnl0ZXNTcGVlZHMubGVuZ3RoOyBi
KyspDQoJCQkJCQkJCWQgKz0gdGhpcy5ieXRlc1NwZWVkc1tiXTsNCgkJCQkJCQl0aGlzLmJ5dGVz
U3BlZWQgPSBNYXRoLnJvdW5kKGQgLyB0aGlzLmJ5dGVzU3BlZWRzLmxlbmd0aCk7DQoJCQkJCQkJ
dGhpcy5yZW1haW5UaW1lID0gTWF0aC5jZWlsKChhLmJ5dGVzVG90YWwgLSBhLmJ5dGVzTG9hZGVk
KSAvIHRoaXMuYnl0ZXNTcGVlZCk7DQoJCQkJCQl9DQoJCQkJCQl0aGlzLmZpcmUoInVwbG9hZHBy
b2dyZXNzIiwgew0KCQkJCQkJCQkJb3JpZ2luRXZlbnQgOiBhLA0KCQkJCQkJCQkJYnl0ZXNMb2Fk
ZWQgOiBhLmJ5dGVzTG9hZGVkLA0KCQkJCQkJCQkJYnl0ZXNTcGVlZCA6IHRoaXMuYnl0ZXNTcGVl
ZCwNCgkJCQkJCQkJCWJ5dGVzVG90YWwgOiBhLmJ5dGVzVG90YWwsDQoJCQkJCQkJCQlyZW1haW5U
aW1lIDogdGhpcy5yZW1haW5UaW1lLA0KCQkJCQkJCQkJcGVyY2VudExvYWRlZCA6IE1hdGgubWlu
KDEwMCwgTWF0aC5yb3VuZCgxRTQgKiBhLmJ5dGVzTG9hZGVkIC8gYS5ieXRlc1RvdGFsKSAvIDEw
MCkNCgkJCQkJCQkJfSk7DQoJCQkJCQlicmVhazsNCgkJCQkJY2FzZSAidXBsb2FkY29tcGxldGUi
IDoNCgkJCQkJCXRoaXMuZmlyZSgidXBsb2FkZmluaXNoZWQiLCB7b3JpZ2luRXZlbnQgOiBhfSk7
DQoJCQkJCQlicmVhazsNCgkJCQkJY2FzZSAidXBsb2FkY29tcGxldGVkYXRhIiA6DQoJCQkJCQl0
aGlzLmZpcmUoInVwbG9hZGNvbXBsZXRlIiwgew0KCQkJCQkJCQkJb3JpZ2luRXZlbnQgOiBhLA0K
CQkJCQkJCQkJZGF0YSA6IGEuZGF0YQ0KCQkJCQkJCQl9KTsNCgkJCQkJCWJyZWFrOw0KCQkJCQlj
YXNlICJ1cGxvYWRjYW5jZWwiIDoNCgkJCQkJCXRoaXMuZmlyZSgidXBsb2FkY2FuY2VsIiwge29y
aWdpbkV2ZW50IDogYX0pOw0KCQkJCQkJYnJlYWs7DQoJCQkJCWNhc2UgInVwbG9hZGVycm9yIiA6
DQoJCQkJCQl0aGlzLmZpcmUoInVwbG9hZGVycm9yIiwgew0KCQkJCQkJCQkJb3JpZ2luRXZlbnQg
OiBhLA0KCQkJCQkJCQkJc3RhdHVzIDogYS5zdGF0dXMsDQoJCQkJCQkJCQlzdGF0dXNUZXh0IDog
YS5tZXNzYWdlLA0KCQkJCQkJCQkJc291cmNlIDogYS5zb3VyY2UNCgkJCQkJCQkJfSk7DQoJCQkJ
fQ0KCQl9LA0KCQlzdGFydFVwbG9hZCA6IGZ1bmN0aW9uKHVybCwgcG9zdFZhcnMsIGZpbGVGaWVs
ZE5hbWUpIHsNCgkJCWlmICh0aGlzLmdldCgidXBsb2FkZXIiKSkgew0KCQkJCXZhciB1cGxvYWRl
ciA9IHRoaXMuZ2V0KCJ1cGxvYWRlciIpLCBmaWxlRmllbGROYW1lID0gZmlsZUZpZWxkTmFtZSB8
fCAiRmlsZURhdGEiLCBpZCA9IHRoaXMuZ2V0KCJpZCIpLCBwb3N0VmFycyA9IHBvc3RWYXJzIHx8
IG51bGw7DQoJCQkJdXBsb2FkZXIub24oInVwbG9hZHN0YXJ0IiwgdGhpcy5zd2ZFdmVudEhhbmRs
ZXIsIHRoaXMpOw0KCQkJCXVwbG9hZGVyLm9uKCJ1cGxvYWRwcm9ncmVzcyIsIHRoaXMuc3dmRXZl
bnRIYW5kbGVyLCB0aGlzKTsNCgkJCQl1cGxvYWRlci5vbigidXBsb2FkY29tcGxldGUiLCB0aGlz
LnN3ZkV2ZW50SGFuZGxlciwgdGhpcyk7DQoJCQkJdXBsb2FkZXIub24oInVwbG9hZGNvbXBsZXRl
ZGF0YSIsIHRoaXMuc3dmRXZlbnRIYW5kbGVyLCB0aGlzKTsNCgkJCQl1cGxvYWRlci5vbigidXBs
b2FkZXJyb3IiLCB0aGlzLnN3ZkV2ZW50SGFuZGxlciwgdGhpcyk7DQoJCQkJdGhpcy5yZW1haW5U
aW1lID0gdGhpcy5ieXRlc1NwZWVkID0gdGhpcy5ieXRlc1ByZXZMb2FkZWQgPSAwOw0KCQkJCXRo
aXMuYnl0ZXNTcGVlZHMgPSBbXTsNCgkJCQlpZiAoIXRoaXMucHJlVGltZSkNCgkJCQkJdGhpcy5w
cmVUaW1lID0gKG5ldyBEYXRlKS5nZXRUaW1lKCk7DQoJCQkJdXBsb2FkZXIuY2FsbFNXRigidXBs
b2FkIiwgW2lkLCB1cmwsIHBvc3RWYXJzLCBmaWxlRmllbGROYW1lXSk7DQoJCQl9DQoJCX0sDQoJ
CWNhbmNlbFVwbG9hZCA6IGZ1bmN0aW9uKCkgew0KCQkJdGhpcy5nZXQoInVwbG9hZGVyIikgDQoJ
CQkJJiYgKHRoaXMuZ2V0KCJ1cGxvYWRlciIpLmNhbGxTV0YoImNhbmNlbCIsIFt0aGlzLmdldCgi
aWQiKV0pLCB0aGlzLmZpcmUoInVwbG9hZGNhbmNlbCIpKTsNCgkJfQ0KCX07DQoJDQoJZnVuY3Rp
b24gU3RyZWFtUHJvdmlkZXIoYSkgew0KCQl0aGlzLmJ1dHRvbkJpbmRpbmcgPSB0aGlzLnF1ZXVl
ID0gdGhpcy5maWxlSW5wdXRGaWVsZCA9IG51bGw7DQoJCXRoaXMuY29uZmlnID0gew0KCQkJZW5h
YmxlZCA6ICEwLA0KCQkJbXVsdGlwbGVGaWxlcyA6ICEwLA0KCQkJZHJhZ0FuZERyb3BBcmVhIDog
IiIsDQoJCQlkcmFnQW5kRHJvcFRpcHMgOiAiIiwNCgkJCWZpbGVGaWx0ZXJzIDogYUZpbHRlcnMs
DQoJCQlmaWxlRmllbGROYW1lIDogIkZpbGVEYXRhIiwNCgkJCXNpbUxpbWl0IDogMSwNCgkJCXJl
dHJ5Q291bnQgOiAzLA0KCQkJcG9zdFZhcnNQZXJGaWxlIDoge30sDQoJCQl1cGxvYWRVUkwgOiAi
L3VwbG9hZCINCgkJfTsNCgkJUGFyZW50LmFwcGx5KHRoaXMsIGFyZ3VtZW50cyk7DQoJfQ0KCVN0
cmVhbVByb3ZpZGVyLnByb3RvdHlwZSA9IHsNCgkJY29uc3RydWN0b3IgOiBTdHJlYW1Qcm92aWRl
ciwNCgkJbmFtZSA6ICJzdHJlYW1fcHJvdmlkZXIiLA0KCQlpbml0aWFsaXplcjogZnVuY3Rpb24o
KXsNCgkJCXRoaXMucHVibGlzaCgiZmlsZXNlbGVjdCIpOw0KCQkJdGhpcy5wdWJsaXNoKCJ1cGxv
YWRzdGFydCIpOw0KCQkJdGhpcy5wdWJsaXNoKCJmaWxldXBsb2Fkc3RhcnQiKTsNCgkJCXRoaXMu
cHVibGlzaCgidXBsb2FkcHJvZ3Jlc3MiKTsNCgkJCXRoaXMucHVibGlzaCgidG90YWx1cGxvYWRw
cm9ncmVzcyIpOw0KCQkJdGhpcy5wdWJsaXNoKCJ1cGxvYWRjb21wbGV0ZSIpOw0KCQkJdGhpcy5w
dWJsaXNoKCJhbGx1cGxvYWRzY29tcGxldGUiKTsNCgkJCXRoaXMucHVibGlzaCgidXBsb2FkZXJy
b3IiKTsNCgkJCXRoaXMucHVibGlzaCgiZHJhZ2VudGVyIik7DQoJCQl0aGlzLnB1Ymxpc2goImRy
YWdvdmVyIik7DQoJCQl0aGlzLnB1Ymxpc2goImRyYWdsZWF2ZSIpOw0KCQkJdGhpcy5wdWJsaXNo
KCJkcm9wIik7DQoJCX0sDQoJCXJlbmRlciA6IGZ1bmN0aW9uKGEpIHsNCgkJCWEgJiYgKHRoaXMu
cmVuZGVyVUkoYSksIHRoaXMuYmluZFVJKCkpOw0KCQl9LA0KCQlyZW5kZXJVSSA6IGZ1bmN0aW9u
KGEpIHsNCgkJCXRoaXMuY29udGVudEJveCA9IGE7DQoJCQl0aGlzLmZpbGVJbnB1dEZpZWxkID0g
ZkNyZWF0ZUNvbnRlbnRFbGUoIjxpbnB1dCB0eXBlPSdmaWxlJyBzdHlsZT0ndmlzaWJpbGl0eTpo
aWRkZW47d2lkdGg6MHB4O2hlaWdodDowcHg7Jz4iKTsNCgkJCXRoaXMuY29udGVudEJveC5hcHBl
bmRDaGlsZCh0aGlzLmZpbGVJbnB1dEZpZWxkKTsNCgkJCXRoaXMuZ2V0KCJkcmFnQW5kRHJvcEFy
ZWEiKSAmJiAhdGhpcy5nZXQoImRyYWdBbmREcm9wQXJlYSIpLm5vZGVUeXBlICYmIHRoaXMuc2V0
KCJkcmFnQW5kRHJvcEFyZWEiLCBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCh0aGlzLmdldCgiZHJh
Z0FuZERyb3BBcmVhIikpKTsgDQoJCQliRHJhZ2dhYmxlICYmIHRoaXMuZ2V0KCJkcmFnQW5kRHJv
cEFyZWEiKSAmJiAoZkFkZENsYXNzKHRoaXMuZ2V0KCJkcmFnQW5kRHJvcEFyZWEiKSwgJ3N0cmVh
bS1icm93c2UtZHJhZy1maWxlcy1hcmVhJyksIHRoaXMuZ2V0KCJkcmFnQW5kRHJvcEFyZWEiKS5h
cHBlbmRDaGlsZChmQ3JlYXRlQ29udGVudEVsZSh0aGlzLmdldCgiZHJhZ0FuZERyb3BUaXBzIikp
KSk7DQoJCX0sDQoJCWJpbmRVSSA6IGZ1bmN0aW9uKCkgew0KCQkJdGhpcy5iaW5kU2VsZWN0QnV0
dG9uKCk7DQoJCQl0aGlzLnNldE11bHRpcGxlRmlsZXMoKTsNCgkJCXRoaXMuc2V0RmlsZUZpbHRl
cnMoKTsNCgkJCXRoaXMuYmluZERyb3BBcmVhKCk7DQoJCQl0aGlzLnRyaWdnZXJFbmFibGVkKCk7
DQoJCQl0aGlzLmFmdGVyKCJtdWx0aXBsZUZpbGVzQ2hhbmdlIiwgdGhpcy5zZXRNdWx0aXBsZUZp
bGVzLCB0aGlzKTsNCgkJCXRoaXMuYWZ0ZXIoImZpbGVGaWx0ZXJzQ2hhbmdlIiwgdGhpcy5zZXRG
aWxlRmlsdGVycywgdGhpcyk7DQoJCQl0aGlzLmFmdGVyKCJlbmFibGVkQ2hhbmdlIiwgdGhpcy50
cmlnZ2VyRW5hYmxlZCwgdGhpcyk7DQoJCQl0aGlzLmFmdGVyKCJkcmFnQW5kRHJvcEFyZWFDaGFu
Z2UiLCB0aGlzLmJpbmREcm9wQXJlYSwgdGhpcyk7DQoJCQlmQWRkRXZlbnRMaXN0ZW5lcih0aGlz
LmZpbGVJbnB1dEZpZWxkLCAiY2hhbmdlIiwgZkV4dGVuZCh0aGlzLnVwZGF0ZUZpbGVMaXN0LCB0
aGlzKSk7DQoJCX0sDQoJCWJpbmREcm9wQXJlYSA6IGZ1bmN0aW9uKCkgew0KCQkJdmFyIGEgPSB0
aGlzLmdldCgiZHJhZ0FuZERyb3BBcmVhIik7DQoJCQl0aGlzLmRyb3BCaW5kaW5nID0gZkV4dGVu
ZCh0aGlzLmRyYWdFdmVudEhhbmRsZXIsIHRoaXMpOw0KCQkJbnVsbCAhPT0gYQkmJiAoZkFkZEV2
ZW50TGlzdGVuZXIoYSwgImRyb3AiLCB0aGlzLmRyb3BCaW5kaW5nKSwNCgkJCQkJCQlmQWRkRXZl
bnRMaXN0ZW5lcihhLCAiZHJhZ2VudGVyIiwgdGhpcy5kcm9wQmluZGluZyksDQoJCQkJCQkJZkFk
ZEV2ZW50TGlzdGVuZXIoYSwgImRyYWdvdmVyIiwgdGhpcy5kcm9wQmluZGluZyksDQoJCQkJCQkJ
ZkFkZEV2ZW50TGlzdGVuZXIoYSwgImRyYWdsZWF2ZSIsIHRoaXMuZHJvcEJpbmRpbmcpKTsNCgkJ
fSwNCgkJZHJhZ0V2ZW50SGFuZGxlciA6IGZ1bmN0aW9uKGV2dCkgew0KCQkJZXZ0ID0gZXZ0IHx8
IHdpbmRvdy5ldmVudDsNCgkJCWV2dC5wcmV2ZW50RGVmYXVsdCA/IGV2dC5wcmV2ZW50RGVmYXVs
dCgpIDogZXZ0LnJldHVyblZhbHVlID0gITE7DQoJCQlldnQuc3RvcFByb3BhZ2F0aW9uID8gZXZ0
LnN0b3BQcm9wYWdhdGlvbigpIDogZXZ0LmNhbmNlbEJ1YmJsZSA9ICEwOw0KCQkJc3dpdGNoIChl
dnQudHlwZSkgew0KCQkJCWNhc2UgImRyYWdlbnRlciIgOg0KCQkJCQl0aGlzLmZpcmUoImRyYWdl
bnRlciIpOw0KCQkJCQlicmVhazsNCgkJCQljYXNlICJkcmFnb3ZlciIgOg0KCQkJCQl0aGlzLmZp
cmUoImRyYWdvdmVyIik7DQoJCQkJCWJyZWFrOw0KCQkJCWNhc2UgImRyYWdsZWF2ZSIgOg0KCQkJ
CQl0aGlzLmZpcmUoImRyYWdsZWF2ZSIpOw0KCQkJCQlicmVhazsNCgkJCQljYXNlICJkcm9wIiA6
DQoJCQkJCXZhciBjYWxsYmFjayA9IGZ1bmN0aW9uKGZpbGVzLCBzZWxmKSB7DQoJCQkJCQlmb3Ig
KHZhciBsaXN0ID0gW10sIGMgPSAwOyBjIDwgZmlsZXMubGVuZ3RoOyBjKyspDQoJCQkJCQkJbGlz
dC5wdXNoKG5ldyBTdHJlYW1VcGxvYWRlcihmaWxlc1tjXSkpOw0KCQkJCQkJMCA8IGxpc3QubGVu
Z3RoICYmIHNlbGYuZmlyZSgiZmlsZXNlbGVjdCIsIHtmaWxlTGlzdCA6IGxpc3R9KTsNCgkJCQkJ
fTsNCgkJCQkJaWYgKGJGb2xkZXIpIHsNCgkJCQkJCXZhciBpdGVtcyA9IGV2dC5kYXRhVHJhbnNm
ZXIuaXRlbXM7DQoJCQkJCQlpZiAoaXRlbXMubGVuZ3RoICYmIGl0ZW1zW2l0ZW1zLmxlbmd0aCAt
IDFdKSB7DQoJCQkJCQkJdmFyIGVudHJ5ID0gaXRlbXNbaXRlbXMubGVuZ3RoIC0gMV0ud2Via2l0
R2V0QXNFbnRyeSgpIHx8IGl0ZW1zW2l0ZW1zLmxlbmd0aCAtIDFdLmdldEFzRW50cnkoKTsNCgkJ
CQkJCQllbnRyeSAmJiB0aGlzLnRyYXZlcnNlRmlsZVRyZWUoZW50cnkuZmlsZXN5c3RlbS5yb290
LCBjYWxsYmFjayk7DQoJCQkJCQl9DQoJCQkJCX0gZWxzZSB7DQoJCQkJCQl2YXIgZmlsZXMgPSBl
dnQuZGF0YVRyYW5zZmVyLmZpbGVzOw0KCQkJCQkJaWYgKGV2dC5NT1pfU09VUkNFX01PVVNFKSB7
DQoJCQkJCQkJZm9yICh2YXIgbGlzdCA9IFtdLCBjID0gMDsgYyA8IGZpbGVzLmxlbmd0aDsgYysr
KQ0KCQkJCQkJCQlmaWxlc1tjXS5zaXplID4gMCAmJiBsaXN0LnB1c2goZmlsZXNbY10pOw0KCQkJ
CQkJCWZpbGVzID0gbGlzdDsNCgkJCQkJCX0NCgkJCQkJCWNhbGxiYWNrKGZpbGVzLCB0aGlzKTsN
CgkJCQkJfQ0KCQkJCQl0aGlzLmZpcmUoImRyb3AiKTsNCgkJCX0NCgkJfSwNCgkJdHJhdmVyc2VG
aWxlVHJlZSA6IGZ1bmN0aW9uIChkaXJlY3RvcnksIGNhbGxiYWNrKSB7DQoJCQljYWxsYmFjay5w
ZW5kaW5nIHx8IChjYWxsYmFjay5wZW5kaW5nID0gMCk7DQoJCQljYWxsYmFjay5maWxlcyB8fCAo
Y2FsbGJhY2suZmlsZXMgPSBbXSk7DQoJCQljYWxsYmFjay5wZW5kaW5nKys7DQoJCQl2YXIgc2Vs
ZiA9IHRoaXMsIHJlbGF0aXZlUGF0aCA9IGRpcmVjdG9yeS5mdWxsUGF0aC5yZXBsYWNlKC9eXC8v
LCAiIikucmVwbGFjZSgvKC4rPylcLz8kLywgIiQxLyIpLCByZWFkZXIgPSBkaXJlY3RvcnkuY3Jl
YXRlUmVhZGVyKCk7DQoJCQlyZWFkZXIucmVhZEVudHJpZXMoZnVuY3Rpb24oZW50cmllcykgew0K
CQkJCWNhbGxiYWNrLnBlbmRpbmctLTsNCgkJCQlpZiAoIWVudHJpZXMubGVuZ3RoKSB7DQoJCQkJ
CWZTaG93TWVzc2FnZSgiXHU1RkZEXHU3NTY1XHU3QTdBXHU2NTg3XHU0RUY2XHU1OTM5XHVGRjFB
YCIgKyByZWxhdGl2ZVBhdGggKyBkaXJlY3RvcnkubmFtZSArICJgIiwgdHJ1ZSk7DQoJCQkJfSBl
bHNlIHsNCgkJCQkJZm9yICh2YXIgaSA9IDA7IGkgPCBlbnRyaWVzLmxlbmd0aDsgaSsrKSB7DQoJ
CQkJCQl2YXIgZW50cnkgPSBlbnRyaWVzW2ldOw0KCQkJCQkJaWYgKGVudHJ5LmlzRmlsZSkgew0K
CQkJCQkJCWNhbGxiYWNrLnBlbmRpbmcrKzsNCgkJCQkJCQllbnRyeS5maWxlKGZ1bmN0aW9uKGYp
IHsNCgkJCQkJCQkJZi5SZWxhdGl2ZVBhdGggPSByZWxhdGl2ZVBhdGggKyBmLm5hbWU7IC8qKiBz
ZWxmIGRlZmluZSBhcmd1bWVudCAqLw0KCQkJCQkJCQljYWxsYmFjay5maWxlcy5wdXNoKGYpOw0K
CQkJCQkJCQkoLS1jYWxsYmFjay5wZW5kaW5nID09PSAwKSAmJiBjYWxsYmFjayhjYWxsYmFjay5m
aWxlcywgc2VsZik7DQoJCQkJCQkJfSk7DQoJCQkJCQkJY29udGludWU7DQoJCQkJCQl9DQoJCQkJ
CQlzZWxmLnRyYXZlcnNlRmlsZVRyZWUoZW50cnksIGNhbGxiYWNrKTsNCgkJCQkJfQ0KCQkJCX0N
CgkJCQkoY2FsbGJhY2sucGVuZGluZyA9PT0gMCkgJiYgY2FsbGJhY2soY2FsbGJhY2suZmlsZXMs
IHNlbGYpOw0KCQkJfSk7DQoJCX0sDQoJCXJlYmluZEZpbGVGaWVsZCA6IGZ1bmN0aW9uKCkgew0K
CQkJdGhpcy5maWxlSW5wdXRGaWVsZC5wYXJlbnROb2RlLnJlbW92ZUNoaWxkKHRoaXMuZmlsZUlu
cHV0RmllbGQpOw0KCQkJdGhpcy5maWxlSW5wdXRGaWVsZCA9IGZDcmVhdGVDb250ZW50RWxlKCI8
aW5wdXQgdHlwZT0nZmlsZScgc3R5bGU9J3Zpc2liaWxpdHk6aGlkZGVuO3dpZHRoOjBweDtoZWln
aHQ6MHB4Oyc+Iik7DQoJCQl0aGlzLmNvbnRlbnRCb3guYXBwZW5kQ2hpbGQodGhpcy5maWxlSW5w
dXRGaWVsZCk7DQoJCQl0aGlzLmdldCgiZHJhZ0FuZERyb3BBcmVhIikgJiYgIXRoaXMuZ2V0KCJk
cmFnQW5kRHJvcEFyZWEiKS5ub2RlVHlwZSAmJiB0aGlzLnNldCgiZHJhZ0FuZERyb3BBcmVhIiwg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQodGhpcy5nZXQoImRyYWdBbmREcm9wQXJlYSIpKSk7IA0K
CQkJYkRyYWdnYWJsZSAmJiAoZkFkZENsYXNzKHRoaXMuZ2V0KCJkcmFnQW5kRHJvcEFyZWEiKSwg
J3N0cmVhbS1icm93c2UtZHJhZy1maWxlcy1hcmVhJykpOw0KCQkJdGhpcy5zZXRNdWx0aXBsZUZp
bGVzKCk7DQoJCQl0aGlzLnNldEZpbGVGaWx0ZXJzKCk7DQoJCQlmQWRkRXZlbnRMaXN0ZW5lcih0
aGlzLmZpbGVJbnB1dEZpZWxkLCAiY2hhbmdlIiwgZkV4dGVuZCh0aGlzLnVwZGF0ZUZpbGVMaXN0
LCB0aGlzKSk7DQoJCX0sDQoJCWJpbmRTZWxlY3RCdXR0b24gOiBmdW5jdGlvbigpIHsNCgkJCXRo
aXMuYnV0dG9uQmluZGluZyA9IGZFeHRlbmQodGhpcy5vcGVuRmlsZVNlbGVjdERpYWxvZywgdGhp
cyk7DQoJCQlmQWRkRXZlbnRMaXN0ZW5lcih0aGlzLmNvbnRlbnRCb3gsICJjbGljayIsIHRoaXMu
YnV0dG9uQmluZGluZyk7DQoJCX0sDQoJCXNldE11bHRpcGxlRmlsZXMgOiBmdW5jdGlvbigpIHsN
CgkJCSEwID09PSB0aGlzLmdldCgibXVsdGlwbGVGaWxlcyIpDQoJCQkJCSYmIHRoaXMuZmlsZUlu
cHV0RmllbGQuc2V0QXR0cmlidXRlKCJtdWx0aXBsZSIsICJtdWx0aXBsZSIpDQoJCX0sDQoJCXNl
dEZpbGVGaWx0ZXJzIDogZnVuY3Rpb24oKSB7DQoJCQl2YXIgYSA9IHRoaXMuZ2V0KCJmaWxlRmls
dGVycyIpOw0KCQkJMCA8IGEubGVuZ3RoID8gdGhpcy5maWxlSW5wdXRGaWVsZC5zZXRBdHRyaWJ1
dGUoImFjY2VwdCIsIGENCgkJCQkJCQkuam9pbigiLCIpKSA6IHRoaXMuZmlsZUlucHV0RmllbGQu
c2V0QXR0cmlidXRlKA0KCQkJCQkiYWNjZXB0IiwgIiIpDQoJCX0sDQoJCXRyaWdnZXJFbmFibGVk
IDogZnVuY3Rpb24oKSB7DQoJCQl2YXIgYSA9IHRoaXMuZ2V0KCJkcmFnQW5kRHJvcEFyZWEiKTsN
CgkJCWlmICh0aGlzLmdldCgiZW5hYmxlZCIpICYmIG51bGwgPT09IHRoaXMuYnV0dG9uQmluZGlu
ZykNCgkJCQl0aGlzLmJpbmRTZWxlY3RCdXR0b24oKSwgdGhpcy5iaW5kRHJvcEFyZWEoKSwgZlJl
bW92ZUNsYXNzKGEsICdzdHJlYW0tZGlzYWJsZWQnKTsNCgkJCWVsc2UgaWYgKCF0aGlzLmdldCgi
ZW5hYmxlZCIpICYmIHRoaXMuYnV0dG9uQmluZGluZykgew0KCQkJCWZSZW1vdmVFdmVudExpc3Rl
bmVyKHRoaXMuY29udGVudEJveCwgImNsaWNrIiwgdGhpcy5idXR0b25CaW5kaW5nKSwNCgkJCQl0
aGlzLmJ1dHRvbkJpbmRpbmcgPSBudWxsOw0KCQkJCQ0KCQkJCW51bGwgIT09IGEgJiYgdGhpcy5k
cm9wQmluZGluZyAhPSBudWxsICYmIChmUmVtb3ZlRXZlbnRMaXN0ZW5lcihhLCAiZHJvcCIsIHRo
aXMuZHJvcEJpbmRpbmcpLA0KCQkJCQkJCWZSZW1vdmVFdmVudExpc3RlbmVyKGEsICJkcmFnZW50
ZXIiLCB0aGlzLmRyb3BCaW5kaW5nKSwNCgkJCQkJCQlmUmVtb3ZlRXZlbnRMaXN0ZW5lcihhLCAi
ZHJhZ292ZXIiLCB0aGlzLmRyb3BCaW5kaW5nKSwNCgkJCQkJCQlmUmVtb3ZlRXZlbnRMaXN0ZW5l
cihhLCAiZHJhZ2xlYXZlIiwgdGhpcy5kcm9wQmluZGluZyksDQoJCQkJCQkJZkFkZENsYXNzKGEs
ICdzdHJlYW0tZGlzYWJsZWQnKSk7DQoJCQl9CQkJCQ0KCQl9LA0KCQl1cGRhdGVGaWxlTGlzdCA6
IGZ1bmN0aW9uKGEpIHsNCgkJCWZvciAodmFyIGEgPSBhLnRhcmdldC5maWxlcywgYiA9IFtdLCBj
ID0gMDsgYyA8IGEubGVuZ3RoOyBjKyspIHsNCgkJCQlpZiAoYVtjXS5uYW1lID09ICIuIikgY29u
dGludWU7DQoJCQkJYi5wdXNoKG5ldyBTdHJlYW1VcGxvYWRlcihhW2NdKSk7DQoJCQl9DQoJCQkw
IDwgYi5sZW5ndGggJiYgdGhpcy5maXJlKCJmaWxlc2VsZWN0Iiwge2ZpbGVMaXN0IDogYn0pOw0K
CQkJdGhpcy5yZWJpbmRGaWxlRmllbGQoKTsNCgkJfSwNCgkJb3BlbkZpbGVTZWxlY3REaWFsb2cg
OiBmdW5jdGlvbihhKSB7DQoJCQl0aGlzLmZpbGVJbnB1dEZpZWxkLmNsaWNrICYmIGEudGFyZ2V0
ICE9IHRoaXMuZmlsZUlucHV0RmllbGQgJiYgdGhpcy5maWxlSW5wdXRGaWVsZC5jbGljaygpOw0K
CQl9LA0KCQl1cGxvYWRFdmVudEhhbmRsZXIgOiBmdW5jdGlvbihhKSB7DQoJCQlzd2l0Y2ggKGEu
dHlwZSkgew0KCQkJCWNhc2UgImV4ZWN1dG9yOnVwbG9hZHN0YXJ0IiA6DQoJCQkJCXRoaXMuZmly
ZSgiZmlsZXVwbG9hZHN0YXJ0IiwgYSk7DQoJCQkJCWJyZWFrOw0KCQkJCWNhc2UgImV4ZWN1dG9y
OnVwbG9hZHByb2dyZXNzIiA6DQoJCQkJCXRoaXMuZmlyZSgidXBsb2FkcHJvZ3Jlc3MiLCBhKTsN
CgkJCQkJYnJlYWs7DQoJCQkJY2FzZSAidXBsb2FkZXJxdWV1ZTp0b3RhbHVwbG9hZHByb2dyZXNz
IiA6DQoJCQkJCXRoaXMuZmlyZSgidG90YWx1cGxvYWRwcm9ncmVzcyIsIGEpOw0KCQkJCQlicmVh
azsNCgkJCQljYXNlICJleGVjdXRvcjp1cGxvYWRjb21wbGV0ZSIgOg0KCQkJCQl0aGlzLmZpcmUo
InVwbG9hZGNvbXBsZXRlIiwgYSk7DQoJCQkJCWJyZWFrOw0KCQkJCWNhc2UgInVwbG9hZGVycXVl
dWU6YWxsdXBsb2Fkc2NvbXBsZXRlIiA6DQoJCQkJCXRoaXMucXVldWUgPSBudWxsOw0KCQkJCQl0
aGlzLmZpcmUoImFsbHVwbG9hZHNjb21wbGV0ZSIsIGEpOw0KCQkJCQlicmVhazsNCgkJCQljYXNl
ICJleGVjdXRvcjp1cGxvYWRlcnJvciIgOg0KCQkJCWNhc2UgInVwbG9hZGVycXVldWU6dXBsb2Fk
ZXJyb3IiIDoNCgkJCQkJdGhpcy5maXJlKCJ1cGxvYWRlcnJvciIsIGEpOw0KCQkJCQlicmVhazsN
CgkJCQljYXNlICJleGVjdXRvcjp1cGxvYWRjYW5jZWwiIDoNCgkJCQljYXNlICJ1cGxvYWRlcnF1
ZXVlOnVwbG9hZGNhbmNlbCIgOg0KCQkJCQl0aGlzLmZpcmUoInVwbG9hZGNhbmNlbCIsIGEpOw0K
CQkJfQ0KCQl9LA0KCQl1cGxvYWQgOiBmdW5jdGlvbih1cGxvYWRlciwgdXJsLCBwb3N0VmFycykg
ew0KCQkJdmFyIHVybCA9IHVybCB8fCB0aGlzLmdldCgidXBsb2FkVVJMIiksIHBvc3RWYXJzID0g
Zk1lcmdlSnNvbihwb3N0VmFycywgdGhpcy5nZXQoInBvc3RWYXJzUGVyRmlsZSIpKSwNCgkJCQlk
ID0gdXBsb2FkZXIuaWQsIHBvc3RWYXJzID0gcG9zdFZhcnMuaGFzT3duUHJvcGVydHkoZCkgPyBw
b3N0VmFyc1tkXSA6IHBvc3RWYXJzOw0KCQkJdXBsb2FkZXIgaW5zdGFuY2VvZiBTdHJlYW1VcGxv
YWRlcg0KCQkJCQkmJiAodXBsb2FkZXIub24oInVwbG9hZHN0YXJ0IiwgdGhpcy51cGxvYWRFdmVu
dEhhbmRsZXIsIHRoaXMpLA0KCQkJCQkJdXBsb2FkZXIub24oInVwbG9hZHByb2dyZXNzIiwgdGhp
cy51cGxvYWRFdmVudEhhbmRsZXIsIHRoaXMpLA0KCQkJCQkJdXBsb2FkZXIub24oInVwbG9hZGNv
bXBsZXRlIiwgdGhpcy51cGxvYWRFdmVudEhhbmRsZXIsIHRoaXMpLA0KCQkJCQkJdXBsb2FkZXIu
b24oInVwbG9hZGVycm9yIiwgdGhpcy51cGxvYWRFdmVudEhhbmRsZXIsIHRoaXMpLA0KCQkJCQkJ
dXBsb2FkZXIub24oInVwbG9hZGNhbmNlbCIsIHRoaXMudXBsb2FkRXZlbnRIYW5kbGVyLCB0aGlz
KSwNCgkJCQkJCXVwbG9hZGVyLnN0YXJ0VXBsb2FkKHVybCwgcG9zdFZhcnMsIHRoaXMuZ2V0KCJm
aWxlRmllbGROYW1lIikpKTsNCgkJfQ0KCX07DQoJDQoJdmFyIFN0cmVhbVVwbG9hZGVyID0gZnVu
Y3Rpb24oKXsNCgkJdGhpcy5yZW1haW5UaW1lID0gdGhpcy5ieXRlc1NwZWVkID0gdGhpcy5ieXRl
c1N0YXJ0ID0gdGhpcy5ieXRlc1ByZXZMb2FkZWQgPSAwOw0KCQl0aGlzLmJ5dGVzU3BlZWRzID0g
W107DQoJCXRoaXMucmV0cnlUaW1lcyA9IHRoaXMucHJlVGltZSA9IDA7DQoJCXRoaXMuY29uZmln
ID0gew0KCQkJaWQgOiAiIiwNCgkJCW5hbWUgOiAiIiwNCgkJCXNpemUgOiAiIiwNCgkJCXR5cGUg
OiAiIiwNCgkJCWRhdGVDcmVhdGVkIDogIiIsDQoJCQlkYXRlTW9kaWZpZWQgOiAiIiwNCgkJCXVw
bG9hZGVyIDogIiIsDQoJCQl1cGxvYWRVUkwgOiAiIiwNCgkJCXNlcnZlckFkZHJlc3MgOiAiIiwN
CgkJCXBvcnRpb25TaXplIDogMTA0ODU3NjAsDQoJCQlwYXJhbWV0ZXJzIDoge30sDQoJCQlmaWxl
RmllbGROYW1lIDogIkZpbGVEYXRhIiwNCgkJCXVwbG9hZE1ldGhvZCA6ICJmb3JtVXBsb2FkIg0K
CQl9Ow0KCQlQYXJlbnQuYXBwbHkodGhpcywgYXJndW1lbnRzKTsNCgl9Ow0KCVN0cmVhbVVwbG9h
ZGVyLmlzVmFsaWRGaWxlID0gZnVuY3Rpb24oYSkge3JldHVybiAidW5kZWZpbmVkIiAhPSB0eXBl
b2YgRmlsZSAmJiBhIGluc3RhbmNlb2YgRmlsZTt9Ow0KCVN0cmVhbVVwbG9hZGVyLmNhblVwbG9h
ZCA9IGZ1bmN0aW9uKCkge3JldHVybiAidW5kZWZpbmVkIiAhPSB0eXBlb2YgRm9ybURhdGE7fTsN
CglTdHJlYW1VcGxvYWRlci5wcm90b3R5cGUgPSB7DQoJCWNvbnN0cnVjdG9yIDogU3RyZWFtVXBs
b2FkZXIsDQoJCW5hbWU6ICJleGVjdXRvciIsDQoJCWluaXRpYWxpemVyOiBmdW5jdGlvbihmaWxl
KXsNCgkJCXRoaXMuWEhSID0gbnVsbDsNCgkJCXRoaXMucmV0cnlUaW1lcyA9IDEwOw0KCQkJdGhp
cy5yZXRyaWVkVGltZXMgPSAwOw0KCQkJdGhpcy5maWxlID0gbnVsbDsNCgkJCXRoaXMuZmlsZUlk
ID0gbnVsbDsNCgkJCXRoaXMuZmlsZVBpZWNlID0gMTA0ODU3NjA7LyoqIDEwTS4gKi8NCgkJCXRo
aXMuZmlsZVNpemVWYWx1ZSA9IDA7DQoJCQl0aGlzLmZpbGVTdGFydFBvc1ZhbHVlID0gbnVsbDsN
CgkJCQ0KCQkJdGhpcy5kdXJhdGlvblRpbWUgPSAyMDAwOw0KCQkJdGhpcy54aHJIYW5kbGVyID0g
bnVsbDsNCgkJCQ0KCQkJdmFyIGIgPSBTdHJlYW1VcGxvYWRlci5pc1ZhbGlkRmlsZShmaWxlKSA/
IGZpbGUgOiBTdHJlYW1VcGxvYWRlci5pc1ZhbGlkRmlsZShmaWxlLmZpbGUpCT8gZmlsZS5maWxl
CTogITE7DQoJCQl0aGlzLmdldCgiaWQiKSB8fCB0aGlzLnNldCgiaWQiLCBmR2VuZXJhdGVJZCgi
ZmlsZSIpKTsNCgkJCWlmIChiICYmIFN0cmVhbVVwbG9hZGVyLmNhblVwbG9hZCgpKSB7DQoJCQkJ
aWYgKCF0aGlzLmZpbGUpDQoJCQkJCXRoaXMuZmlsZSA9IGI7DQoJCQkJdGhpcy5zZXQoIm5hbWUi
LCBiLlJlbGF0aXZlUGF0aCB8fCBiLndlYmtpdFJlbGF0aXZlUGF0aCB8fCBiLm5hbWUgfHwgYi5m
aWxlTmFtZSk7DQoJCQkJaWYgKHRoaXMuZ2V0KCJzaXplIikgIT0gKGIuc2l6ZSB8fCBiLmZpbGVT
aXplKSkNCgkJCQkJdGhpcy5zZXQoInNpemUiLCBiLnNpemUgfHwgYi5maWxlU2l6ZSk7DQoJCQkJ
dGhpcy5nZXQoInR5cGUiKSB8fCB0aGlzLnNldCgidHlwZSIsIGIudHlwZSk7DQoJCQkJYi5sYXN0
TW9kaWZpZWREYXRlICYmICF0aGlzLmdldCgiZGF0ZU1vZGlmaWVkIikJJiYgdGhpcy5zZXQoImRh
dGVNb2RpZmllZCIsIGIubGFzdE1vZGlmaWVkRGF0ZSk7DQoJCQl9DQoJCX0sDQoJCXJlc2V0WGhy
OiBmdW5jdGlvbigpew0KCQkJaWYodGhpcy5YSFIpew0KCQkJCXRyeXsNCgkJCQkJdGhpcy5YSFIu
dXBsb2FkLnJlbW92ZUV2ZW50TGlzdGVuZXIoInByb2dyZXNzIiwgdGhpcy54aHJIYW5kbGVyKSwN
CgkJCQkJdGhpcy5YSFIudXBsb2FkLnJlbW92ZUV2ZW50TGlzdGVuZXIoImVycm9yIiwgdGhpcy54
aHJIYW5kbGVyKSwNCgkJCQkJdGhpcy5YSFIudXBsb2FkLnJlbW92ZUV2ZW50TGlzdGVuZXIoImFi
b3J0IiwgdGhpcy54aHJIYW5kbGVyKSwNCgkJCQkJdGhpcy5YSFIucmVtb3ZlRXZlbnRMaXN0ZW5l
cigibG9hZGVuZCIsIHRoaXMueGhySGFuZGxlciksDQoJCQkJCXRoaXMuWEhSLnJlbW92ZUV2ZW50
TGlzdGVuZXIoImVycm9yIiwgdGhpcy54aHJIYW5kbGVyKSwNCgkJCQkJdGhpcy5YSFIucmVtb3Zl
RXZlbnRMaXN0ZW5lcigiYWJvcnQiLCB0aGlzLnhockhhbmRsZXIpLA0KCQkJCQl0aGlzLlhIUi5y
ZW1vdmVFdmVudExpc3RlbmVyKCJyZWFkeXN0YXRlY2hhbmdlIiwgdGhpcy54aHJIYW5kbGVyKTsN
CgkJCQl9Y2F0Y2goZSl7dGhyb3cgZTt9DQoJCQkJdGhpcy5YSFIgPSBudWxsOw0KCQkJfQ0KCQl9
LA0KCQlmb3JtVXBsb2FkIDogZnVuY3Rpb24oKSB7DQoJCQl0aGlzLnJlc2V0WGhyKCk7DQoJCQl0
aGlzLlhIUiA9IG5ldyBYTUxIdHRwUmVxdWVzdDsNCgkJCXRoaXMudXBsb2FkRXZlbnRIYW5kbGVy
ID0gZkV4dGVuZCh0aGlzLnVwbG9hZEV2ZW50SGFuZGxlciwgdGhpcyk7DQoJCQl2YXIgZmQgPSBu
ZXcgRm9ybURhdGEsIGZpbGVGaWxlTmFtZSA9IHRoaXMuZ2V0KCJmaWxlRmllbGROYW1lIiksDQoJ
CQkJdXJsID0gdGhpcy5nZXQoInVwbG9hZFVSTCIpLCBfeGhyID0gdGhpcy5YSFIsIF91cGxvYWQg
PSBfeGhyLnVwbG9hZDsNCgkJCXRoaXMuc2V0KCJ1cGxvYWRNZXRob2QiLCAiZm9ybVVwbG9hZCIp
Ow0KCQkJdGhpcy5ieXRlc1N0YXJ0ID0gMDsNCgkJCXRoaXMucHJlVGltZSA9IChuZXcgRGF0ZSku
Z2V0VGltZSgpOw0KCQkJZmQuYXBwZW5kKGZpbGVGaWxlTmFtZSwgdGhpcy5maWxlKTsNCgkJCV94
aHIuYWRkRXZlbnRMaXN0ZW5lcigibG9hZHN0YXJ0IiwgdGhpcy51cGxvYWRFdmVudEhhbmRsZXIs
ICExKTsNCgkJCV91cGxvYWQuYWRkRXZlbnRMaXN0ZW5lcigicHJvZ3Jlc3MiLCB0aGlzLnVwbG9h
ZEV2ZW50SGFuZGxlciwgITEpOw0KCQkJX3hoci5hZGRFdmVudExpc3RlbmVyKCJsb2FkIiwgdGhp
cy51cGxvYWRFdmVudEhhbmRsZXIsICExKTsNCgkJCV94aHIuYWRkRXZlbnRMaXN0ZW5lcigiZXJy
b3IiLCB0aGlzLnVwbG9hZEV2ZW50SGFuZGxlciwgITEpOw0KCQkJX3VwbG9hZC5hZGRFdmVudExp
c3RlbmVyKCJlcnJvciIsIHRoaXMudXBsb2FkRXZlbnRIYW5kbGVyLCAhMSk7DQoJCQlfdXBsb2Fk
LmFkZEV2ZW50TGlzdGVuZXIoImFib3J0IiwgdGhpcy51cGxvYWRFdmVudEhhbmRsZXIsICExKTsN
CgkJCV94aHIuYWRkRXZlbnRMaXN0ZW5lcigiYWJvcnQiLCB0aGlzLnVwbG9hZEV2ZW50SGFuZGxl
ciwgITEpOw0KCQkJX3hoci5hZGRFdmVudExpc3RlbmVyKCJsb2FkZW5kIiwgdGhpcy51cGxvYWRF
dmVudEhhbmRsZXIsICExKTsNCgkJCV94aHIuYWRkRXZlbnRMaXN0ZW5lcigicmVhZHlzdGF0ZWNo
YW5nZSIsIHRoaXMudXBsb2FkRXZlbnRIYW5kbGVyLCAhMSk7DQoJCQlfeGhyLm9wZW4oIlBPU1Qi
LCB1cmwsICEwKTsNCgkJCV94aHIuc2VuZChmZCk7DQoJCQl0aGlzLmZpcmUoInVwbG9hZHN0YXJ0
Iiwge3hociA6IF94aHJ9KTsNCgkJfSwNCgkJc3RyZWFtVXBsb2FkOiBmdW5jdGlvbihwb3Mpew0K
CQkJLyoqIHdoZXRoZXIgY29udGludWUgdXBsb2FkaW5nLiAqLw0KCQkJdmFyIF91cmwgPSB0aGlz
LmdldCgidXBsb2FkVVJMIik7DQoJCQl0aGlzLnJlc2V0WGhyKCk7DQoJCQl0aGlzLnJlc3VtZSA9
IGZhbHNlOw0KCQkJdGhpcy5ieXRlc1N0YXJ0ID0gcG9zOw0KCQkJdGhpcy5YSFIgPSBuZXcgWE1M
SHR0cFJlcXVlc3Q7DQoJCQl0aGlzLnhockhhbmRsZXIgPSBmRXh0ZW5kKHRoaXMudXBsb2FkRXZl
bnRIYW5kbGVyLCB0aGlzKTsNCgkJCS8vcmVnaXN0ZXIgY2FsbGJhY2sgZnVuY3Rpb24NCgkJCXZh
ciBfeGhyID0gdGhpcy5YSFIsIHVwbG9hZCA9IF94aHIudXBsb2FkOw0KCQkJX3hoci5hZGRFdmVu
dExpc3RlbmVyKCJsb2Fkc3RhcnQiLCB0aGlzLnhockhhbmRsZXIsICExKTsNCgkJCXVwbG9hZC5h
ZGRFdmVudExpc3RlbmVyKCJwcm9ncmVzcyIsIHRoaXMueGhySGFuZGxlciwgITEpOw0KCQkJX3ho
ci5hZGRFdmVudExpc3RlbmVyKCJsb2FkIiwgdGhpcy54aHJIYW5kbGVyLCAhMSk7DQoJCQlfeGhy
LmFkZEV2ZW50TGlzdGVuZXIoImVycm9yIiwgdGhpcy54aHJIYW5kbGVyLCAhMSk7DQoJCQl1cGxv
YWQuYWRkRXZlbnRMaXN0ZW5lcigiZXJyb3IiLCB0aGlzLnhockhhbmRsZXIsICExKTsNCgkJCXVw
bG9hZC5hZGRFdmVudExpc3RlbmVyKCJhYm9ydCIsIHRoaXMueGhySGFuZGxlciwgITEpOw0KCQkJ
X3hoci5hZGRFdmVudExpc3RlbmVyKCJhYm9ydCIsIHRoaXMueGhySGFuZGxlciwgITEpOw0KCQkJ
X3hoci5hZGRFdmVudExpc3RlbmVyKCJsb2FkZW5kIiwgdGhpcy54aHJIYW5kbGVyLCAhMSk7DQoJ
CQlfeGhyLmFkZEV2ZW50TGlzdGVuZXIoInJlYWR5c3RhdGVjaGFuZ2UiLCB0aGlzLnhockhhbmRs
ZXIsICExKTsNCgkJCXZhciBibG9iID0gdGhpcy5zbGljZUZpbGUodGhpcy5maWxlLCBwb3MsIHBv
cyArIHRoaXMuZmlsZVBpZWNlKTsNCgkJCXZhciByYW5nZSA9ICJieXRlcyAiKyBwb3MgKyAiLSIr
IChwb3MgKyBibG9iLnNpemUpICsgIi8iICsgdGhpcy5nZXQoInNpemUiKTsNCgkJCXRoaXMucHJl
VGltZSA9IChuZXcgRGF0ZSkuZ2V0VGltZSgpOw0KCQkJX3hoci5vcGVuKCJQT1NUIiwgX3VybCwg
ITApOw0KCQkJX3hoci5zZXRSZXF1ZXN0SGVhZGVyKCJDb250ZW50LVJhbmdlIiwgcmFuZ2UpOw0K
CQkJX3hoci5zZW5kKGJsb2IpOw0KCQkJMCA9PT0gcG9zICYmIHRoaXMuZmlyZSgidXBsb2Fkc3Rh
cnQiLCB7eGhyIDogX3hocn0pOw0KCQl9LA0KCQlyZXN1bWVVcGxvYWQ6IGZ1bmN0aW9uKCkgew0K
CQkJLyoqIHdoZW4gQnJvd3NlIGhhcyBgRmlsZWAsIGJ1dCBoYXMgbm90IGBGaWxlLnNsaWNlYCAq
Lw0KCQkJaWYgKCFiRmlsZVNsaWNlKSB7DQoJCQkJdGhpcy5mb3JtVXBsb2FkKCk7DQoJCQkJcmV0
dXJuOw0KCQkJfQ0KCQkJDQoJCQl0aGlzLnJlc2V0WGhyKCk7DQoJCQl0aGlzLlhIUiA9IG5ldyBY
TUxIdHRwUmVxdWVzdDsNCgkJCXRoaXMucmVzdW1lID0gdHJ1ZTsNCgkJCQ0KCQkJdmFyIF91cmwg
PSB0aGlzLmdldCgidXBsb2FkVVJMIikgKyAiJiIgKyBmR2V0UmFuZG9tKCk7DQoJCQl0aGlzLnho
ckhhbmRsZXIgPSBmRXh0ZW5kKHRoaXMudXBsb2FkRXZlbnRIYW5kbGVyLCB0aGlzKTsNCgkJCXRo
aXMuWEhSLmFkZEV2ZW50TGlzdGVuZXIoImxvYWRzdGFydCIsIHRoaXMueGhySGFuZGxlciwgITEp
Ow0KCQkJdGhpcy5YSFIuYWRkRXZlbnRMaXN0ZW5lcigibG9hZCIsIHRoaXMueGhySGFuZGxlciwg
ITEpOw0KCQkJdGhpcy5YSFIuYWRkRXZlbnRMaXN0ZW5lcigiYWJvcnQiLCB0aGlzLnhockhhbmRs
ZXIsICExKTsNCgkJCXRoaXMuWEhSLmFkZEV2ZW50TGlzdGVuZXIoImVycm9yIiwgdGhpcy54aHJI
YW5kbGVyLCAhMSk7DQoJCQl0aGlzLlhIUi5hZGRFdmVudExpc3RlbmVyKCJsb2FkZW5kIiwgdGhp
cy54aHJIYW5kbGVyLCAhMSk7DQoJCQl0aGlzLlhIUi5hZGRFdmVudExpc3RlbmVyKCJyZWFkeXN0
YXRlY2hhbmdlIiwgdGhpcy54aHJIYW5kbGVyLCAhMSk7DQoJCQl0aGlzLnByZVRpbWUgPSAobmV3
IERhdGUpLmdldFRpbWUoKTsNCgkJCXRoaXMuWEhSLm9wZW4oIkdFVCIsIF91cmwsICEwKTsNCgkJ
CXRoaXMuWEhSLnNlbmQobnVsbCk7DQoJCX0sDQoJCXJldHJ5OiBmdW5jdGlvbigpew0KICAgICAg
ICAgICAgdGhpcy5yZXRyaWVkVGltZXMrKzsNCiAgICAgICAgICAgIHZhciBnID0gdGhpczsNCiAg
ICAgICAgICAgIDIgPiB0aGlzLnJldHJpZWRUaW1lcyA/IHRoaXMucmVzdW1lVXBsb2FkKCkNCiAg
ICAgICAgICAgIAkJCQkJOiAodGhpcy50aW1lb3V0SGFuZGxlciAmJiBjbGVhclRpbWVvdXQodGhp
cy50aW1lb3V0SGFuZGxlciksIHRoaXMudGltZW91dEhhbmRsZXIgPSBzZXRUaW1lb3V0KGZ1bmN0
aW9uKCkge2cucmVzdW1lVXBsb2FkKCl9LCAxRTQpKTsNCgkJfSwNCgkJdXBsb2FkRXZlbnRIYW5k
bGVyOiBmdW5jdGlvbihldmVudCl7DQoJCQl2YXIgeGhyID0gdGhpcy5YSFIsIG1ldGhvZCA9IHRo
aXMuZ2V0KCJ1cGxvYWRNZXRob2QiKTsNCgkJCXN3aXRjaChldmVudC50eXBlKXsNCgkJCQljYXNl
ICJsb2FkIjoNCgkJCQkJdmFyIHVwbG9hZGVkID0gMDsNCgkJCQkJdmFyIHJlc3BKc29uID0gbnVs
bDsNCgkJCQkJdmFyIGJFcnJvciA9ICExOw0KCQkJCQl0cnkgew0KCQkJCQkJaWYgKHhoci5yZWFk
eVN0YXRlID09IDQgJiYgKHhoci5zdGF0dXMgPT0gMjAwIHx8IHhoci5zdGF0dXMgPT0gMzA4KSkg
ew0KCQkJCQkJCXVwbG9hZGVkID0gKHJlc3BKc29uID0gZXZhbCgiKCIgKyB4aHIucmVzcG9uc2VU
ZXh0ICsgIikiKSkgPyByZXNwSnNvbi5zdGFydCA6IC0xOw0KCQkJCQkJfSBlbHNlIGlmICh4aHIu
c3RhdHVzIDwgNTAwICYmIHhoci5zdGF0dXMgPj0gNDAwKSB7DQoJCQkJCQkJYkVycm9yID0gITA7
DQoJCQkJCQl9IGVsc2UgaWYgKHhoci5zdGF0dXMgPCAyMDApIHtyZXR1cm47fQ0KCQkJCQkJLyoq
IHRoZSByZXNwb25zZSBjYW4ndCBwcm9jZXNzIHRoZSByZXF1ZXN0LCBzbyB0aHJvd3Mgb3V0IHRo
ZSBlcnJvci4gKi8NCgkJCQkJCWJFcnJvciA9IGJFcnJvciB8fCByZXNwSnNvbi5zdWNjZXNzID09
IGZhbHNlOw0KCQkJCQl9IGNhdGNoKGUpIHsNCgkJCQkJCWJFcnJvciA9ICJmb3JtVXBsb2FkIiA9
PT0gbWV0aG9kIHx8IHRoaXMucmV0cmllZFRpbWVzID4gdGhpcy5yZXRyeVRpbWVzOw0KCQkJCQkJ
aWYgKCFiRXJyb3IpIHsNCgkJCQkJCQl0aGlzLnJldHJ5KCk7DQoJCQkJCQkJcmV0dXJuOw0KCQkJ
CQkJfQ0KCQkJCQl9DQoJCQkJCWlmIChiRXJyb3IpIHsNCgkJCQkJCXRoaXMuZmlyZSgidXBsb2Fk
ZXJyb3IiLCB7DQoJCQkJCQkJb3JpZ2luRXZlbnQgOiBldmVudCwNCgkJCQkJCQlzdGF0dXMgOiB4
aHIuc3RhdHVzLA0KCQkJCQkJCXN0YXR1c1RleHQgOiB4aHIucmVzcG9uc2VUZXh0LA0KCQkJCQkJ
CXNvdXJjZSA6IHJlc3BKc29uICYmIHJlc3BKc29uLm1lc3NhZ2UNCgkJCQkJCX0pOw0KCQkJCQkJ
cmV0dXJuOw0KCQkJCQl9DQoJCQkJCS8vY2hlY2sgd2hldGhlciB1cGxvYWQgY29tcGxldGUgeWV0
DQoJCQkJCWlmKHVwbG9hZGVkIDwgdGhpcy5nZXQoInNpemUiKSAtMSkgew0KCQkJCQkJdGhpcy5y
ZXRyaWVkVGltZXMgPSAwOw0KCQkJCQkJLyoqIFN0cmVhbVVwbG9hZGVyIHJlcXVlc3QgaXMgb3Zl
ciBhbmQgbWFyayB0aGUgZGF0ZS4gKi8NCgkJCQkJCXRoaXMuc3RyZWFtVXBsb2FkKHVwbG9hZGVk
KTsNCgkJCQkJfSBlbHNlIHsNCgkJCQkJCXRoaXMuZmlyZSgidXBsb2FkY29tcGxldGUiLCB7b3Jp
Z2luRXZlbnQgOiBldmVudCwgZGF0YSA6IGV2ZW50LnRhcmdldC5yZXNwb25zZVRleHR9KTsNCgkJ
CQkJfQ0KCQkJCQlicmVhazsNCgkJCQljYXNlICJlcnJvciI6DQoJCQkJCXRoaXMucmV0cmllZFRp
bWVzIDwgdGhpcy5yZXRyeVRpbWVzID8gdGhpcy5yZXRyeSgpDQoJCQkJCQk6IHRoaXMuZmlyZSgi
dXBsb2FkZXJyb3IiLCB7DQoJCQkJCQkJCQlvcmlnaW5FdmVudCA6IGV2ZW50LA0KCQkJCQkJCQkJ
c3RhdHVzIDogeGhyLnN0YXR1cywNCgkJCQkJCQkJCXN0YXR1c1RleHQgOiB4aHIuc3RhdHVzVGV4
dCwNCgkJCQkJCQkJCXNvdXJjZSA6ICJpbyINCgkJCQkJCQkJfSk7DQoJCQkJCWJyZWFrOw0KCQkJ
CWNhc2UgImFib3J0IjoNCgkJCQkJdGhpcy5maXJlKCJ1cGxvYWRjYW5jZWwiLCB7b3JpZ2luRXZl
bnQgOiBldmVudH0pOw0KCQkJCQlicmVhazsNCgkJCQljYXNlICJwcm9ncmVzcyI6DQoJCQkJCXZh
ciB0b3RhbCA9IHRoaXMuZ2V0KCJzaXplIiksIGxvYWRlZCA9IHRoaXMuYnl0ZXNTdGFydCArIGV2
ZW50LmxvYWRlZCwNCgkJCQkJCW5vdyA9IChuZXcgRGF0ZSkuZ2V0VGltZSgpLCBjb3N0ID0gKG5v
dyAtIHRoaXMucHJlVGltZSkgLyAxRTMsIHRvdGFsU3BlZWRzID0gMDsNCgkJCQkJaWYgKDAuNjgg
PD0gY29zdCB8fCAwID09PSB0aGlzLmJ5dGVzU3BlZWRzLmxlbmd0aCkgew0KCQkJCQkJdGhpcy5i
eXRlc1ByZXZMb2FkZWQgPSBNYXRoLm1heCh0aGlzLmJ5dGVzU3RhcnQsIHRoaXMuYnl0ZXNQcmV2
TG9hZGVkKTsNCgkJCQkJCXRoaXMuYnl0ZXNTcGVlZCA9IE1hdGgucm91bmQoKGxvYWRlZCAtIHRo
aXMuYnl0ZXNQcmV2TG9hZGVkKSAvIGNvc3QpOw0KCQkJCQkJdGhpcy5ieXRlc1ByZXZMb2FkZWQg
PSBsb2FkZWQ7DQoJCQkJCQl0aGlzLnByZVRpbWUgPSBub3c7DQoJCQkJCQk1IDwgdGhpcy5ieXRl
c1NwZWVkcy5sZW5ndGggJiYgdGhpcy5ieXRlc1NwZWVkcy5zaGlmdCgpOw0KCQkJCQkJNSA+IHRo
aXMuYnl0ZXNTcGVlZHMubGVuZ3RoICYmICh0aGlzLmJ5dGVzU3BlZWQgPSB0aGlzLmJ5dGVzU3Bl
ZWQgLyAyKTsNCgkJCQkJCXRoaXMuYnl0ZXNTcGVlZHMucHVzaCh0aGlzLmJ5dGVzU3BlZWQpOw0K
CQkJCQkJZm9yICh2YXIgaSA9IDA7IGkgPCB0aGlzLmJ5dGVzU3BlZWRzLmxlbmd0aDsgaSsrKQ0K
CQkJCQkJCXRvdGFsU3BlZWRzICs9IHRoaXMuYnl0ZXNTcGVlZHNbaV07DQoJCQkJCQl0aGlzLmJ5
dGVzU3BlZWQgPSBNYXRoLnJvdW5kKHRvdGFsU3BlZWRzIC8gdGhpcy5ieXRlc1NwZWVkcy5sZW5n
dGgpOw0KCQkJCQkJdGhpcy5yZW1haW5UaW1lID0gTWF0aC5jZWlsKCh0b3RhbCAtIGxvYWRlZCkg
LyB0aGlzLmJ5dGVzU3BlZWQpOw0KCQkJCQl9DQoJCQkJCXRoaXMuZmlyZSgidXBsb2FkcHJvZ3Jl
c3MiLCB7DQoJCQkJCQkJCW9yaWdpbkV2ZW50IDogZXZlbnQsDQoJCQkJCQkJCWJ5dGVzTG9hZGVk
IDogbG9hZGVkLA0KCQkJCQkJCQlieXRlc1RvdGFsIDogdG90YWwsDQoJCQkJCQkJCWJ5dGVzU3Bl
ZWQgOiB0aGlzLmJ5dGVzU3BlZWQsDQoJCQkJCQkJCXJlbWFpblRpbWUgOiB0aGlzLnJlbWFpblRp
bWUsDQoJCQkJCQkJCXBlcmNlbnRMb2FkZWQgOiBNYXRoLm1pbigxMDAsIE1hdGguZmxvb3IoMUU0
ICogbG9hZGVkIC8gdG90YWwpIC8gMTAwKQ0KCQkJCQkJCX0pOw0KCQkJCQlicmVhazsNCgkJCQlj
YXNlICJyZWFkeXN0YXRlY2hhbmdlIjoNCgkJCQkJdGhpcy5maXJlKCJyZWFkeXN0YXRlY2hhbmdl
Iiwge3JlYWR5U3RhdGUgOiBldmVudC50YXJnZXQucmVhZHlTdGF0ZSwgb3JpZ2luRXZlbnQgOiBl
dmVudH0pOw0KCQkJfQ0KCQl9LA0KCQlzdGFydFVwbG9hZDogZnVuY3Rpb24odXJsLCBwb3N0VmFy
cywgZmlsZUZpZWxkTmFtZSl7DQoJCQl0aGlzLmZpbGVTdGFydFBvc1ZhbHVlID0gbnVsbDsNCgkJ
CXRoaXMucmV0cmllZFRpbWVzID0gMDsNCg0KCQkJcG9zdFZhcnMubmFtZSA9IHRoaXMuZ2V0KCJu
YW1lIik7DQoJCQlwb3N0VmFycy5zaXplID0gdGhpcy5nZXQoInNpemUiKTsNCgkJCXZhciBtZXRo
b2QgPSB0aGlzLmdldCgidXBsb2FkTWV0aG9kIik7DQoJCQl0aGlzLnNldCgidXBsb2FkVVJMIiwg
ZkFkZFZhcnMocG9zdFZhcnMsIHVybCkpOw0KCQkJdGhpcy5zZXQoInBhcmFtZXRlcnMiLCBwb3N0
VmFycyk7DQoJCQl0aGlzLnNldCgiZmlsZUZpZWxkTmFtZSIsIGZpbGVGaWVsZE5hbWUpOw0KCQkJ
dGhpcy5yZW1haW5UaW1lID0gdGhpcy5ieXRlc1NwZWVkID0gdGhpcy5ieXRlc1ByZXZMb2FkZWQg
PSAwOw0KCQkJdGhpcy5ieXRlc1NwZWVkcyA9IFtdOw0KCQkJdGhpcy5yZXNldFhocigpOw0KCQkJ
c3dpdGNoIChtZXRob2QpIHsNCgkJCQljYXNlICJmb3JtVXBsb2FkIiA6DQoJCQkJCXRoaXMuZm9y
bVVwbG9hZCgpOw0KCQkJCQlicmVhazsNCgkJCQljYXNlICJzdHJlYW1VcGxvYWQiIDoNCgkJCQkJ
dGhpcy5zdHJlYW1VcGxvYWQoKTsNCgkJCQkJYnJlYWs7DQoJCQkJY2FzZSAicmVzdW1lVXBsb2Fk
IiA6DQoJCQkJCXRoaXMucmVzdW1lVXBsb2FkKCkNCgkJCX0NCgkJfSwNCgkJc2xpY2VGaWxlOiBm
dW5jdGlvbihmLCBzdGFydFBvcywgZW5kUG9zKXsNCgkJCXN0YXJ0UG9zID0gc3RhcnRQb3MgfHwg
MDsNCgkJCWVuZFBvcyA9IGVuZFBvcyB8fCAwOw0KCQkJcmV0dXJuIGYuc2xpY2UgPyBmLnNsaWNl
KHN0YXJ0UG9zLCBlbmRQb3MpIDogZi53ZWJraXRTbGljZSA/IGYud2Via2l0U2xpY2Uoc3RhcnRQ
b3MsIGVuZFBvcykgOiBmLm1velNsaWNlID8gZi5tb3pTbGljZShzdGFydFBvcywgZW5kUG9zKSA6
IGY7DQoJCX0sDQoJCWNhbmNlbFVwbG9hZCA6IGZ1bmN0aW9uKCkgew0KCQkJdGhpcy5YSFIgJiYg
KHRoaXMuWEhSLmFib3J0KCksIHRoaXMucmVzZXRYaHIoKSk7DQoJCX0NCgl9Ow0KCQ0KCWZ1bmN0
aW9uIE1haW4oY2ZnKXsNCgkJY2ZnID0gY2ZnIHx8IHt9Ow0KCQlhRmlsdGVycyA9IGZJc0FycmF5
KGNmZy5leHRGaWx0ZXJzKSA/IGNmZy5leHRGaWx0ZXJzIDogYUZpbHRlcnM7DQoJCXRoaXMuYlN0
cmVhbWluZyA9IGJTdHJlYW1pbmc7DQoJCXRoaXMuYkRyYWdnYWJsZSA9IGJEcmFnZ2FibGU7DQoJ
CXRoaXMudXBsb2FkSW5mbyA9IHt9Ow0KCQl0aGlzLmNvbmZpZyA9IHsNCgkJCWVuYWJsZWQgOiAh
MCwNCgkJCWN1c3RvbWVyZWQgOiAhIWNmZy5jdXN0b21lcmVkLA0KCQkJbXVsdGlwbGVGaWxlcyA6
ICEhY2ZnLm11bHRpcGxlRmlsZXMsDQoJCQlhdXRvUmVtb3ZlQ29tcGxldGVkIDogISFjZmcuYXV0
b1JlbW92ZUNvbXBsZXRlZCwNCgkJCWF1dG9VcGxvYWRpbmcgOiBjZmcuYXV0b1VwbG9hZGluZyA9
PSBudWxsID8gdHJ1ZSA6ICEhY2ZnLmF1dG9VcGxvYWRpbmcsDQoJCQlkcmFnQW5kRHJvcEFyZWE6
IGNmZy5kcmFnQW5kRHJvcEFyZWEsDQoJCQlkcmFnQW5kRHJvcFRpcHM6IGNmZy5kcmFnQW5kRHJv
cFRpcHMgfHwgIjxzcGFuPuaKiuaWh+S7tijmlofku7blpLkp5ouW5ou95Yiw6L+Z6YeMPC9zcGFu
PiIsDQoJCQlmaWxlRmllbGROYW1lIDogY2ZnLmZpbGVGaWVsZE5hbWUgfHwgIkZpbGVEYXRhIiwN
CgkJCWJyb3dzZUZpbGVJZCA6IGNmZy5icm93c2VGaWxlSWQgfHwgImlfc2VsZWN0X2ZpbGVzIiwN
CgkJCWJyb3dzZUZpbGVCdG4gOiBjZmcuYnJvd3NlRmlsZUJ0biB8fCAiPGRpdj7or7fpgInmi6nm
lofku7Y8L2Rpdj4iLA0KCQkJZmlsZXNRdWV1ZUlkIDogY2ZnLmZpbGVzUXVldWVJZCB8fCAiaV9z
dHJlYW1fZmlsZXNfcXVldWUiLA0KCQkJZmlsZXNRdWV1ZUhlaWdodCA6IGNmZy5maWxlc1F1ZXVl
SGVpZ2h0IHx8IDQ1MCwNCgkJCW1lc3NhZ2VySWQgOiBjZmcubWVzc2FnZXJJZCB8fCAiaV9zdHJl
YW1fbWVzc2FnZV9jb250YWluZXIiLA0KCQkJb25TZWxlY3QgOiBjZmcub25TZWxlY3QsDQoJCQlv
bkFkZFRhc2s6IGNmZy5vbkFkZFRhc2ssDQoJCQlvbk1heFNpemVFeGNlZWQgOiBjZmcub25NYXhT
aXplRXhjZWVkLA0KCQkJb25GaWxlQ291bnRFeGNlZWQgOiBjZmcub25GaWxlQ291bnRFeGNlZWQs
DQoJCQlvbkV4dE5hbWVNaXNtYXRjaCA6IGNmZy5vbkV4dE5hbWVNaXNtYXRjaCwNCgkJCW9uQ2Fu
Y2VsIDogY2ZnLm9uQ2FuY2VsLA0KCQkJb25TdG9wIDogY2ZnLm9uU3RvcCwNCgkJCW9uQ2FuY2Vs
QWxsIDogY2ZnLm9uQ2FuY2VsQWxsLA0KCQkJb25Db21wbGV0ZSA6IGNmZy5vbkNvbXBsZXRlLA0K
CQkJb25RdWV1ZUNvbXBsZXRlOiBjZmcub25RdWV1ZUNvbXBsZXRlLA0KCQkJb25VcGxvYWRQcm9n
cmVzczogY2ZnLm9uVXBsb2FkUHJvZ3Jlc3MsDQoJCQlvblVwbG9hZEVycm9yOiBjZmcub25VcGxv
YWRFcnJvciwNCgkJCW1heFNpemUgOiBjZmcubWF4U2l6ZSB8fCAyMTQ3NDgzNjQ4LA0KCQkJc2lt
TGltaXQgOiBjZmcuc2ltTGltaXQgfHwgMTAwMDAsDQoJCQlhRmlsdGVyczogYUZpbHRlcnMsDQoJ
CQlyZXRyeUNvdW50IDogY2ZnLnJldHJ5Q291bnQgfHwgNSwNCgkJCXBvc3RWYXJzUGVyRmlsZSA6
IGNmZy5wb3N0VmFyc1BlckZpbGUgfHwge30sDQoJCQlzd2ZVUkwgOiBjZmcuc3dmVVJMIHx8ICIv
Rmxhc2hVcGxvYWRlci5zd2YiLA0KCQkJdG9rZW5VUkwgOiBjZmcudG9rZW5VUkwgfHwgIi90ayIs
DQoJCQlmcm1VcGxvYWRVUkwgOiBjZmcuZnJtVXBsb2FkVVJMIHx8IEJyb3dzZXIuZmlyZWZveCA/
ICIvZmQ7IiArIGRvY3VtZW50LmNvb2tpZSA6ICIvZmQiLA0KCQkJdXBsb2FkVVJMIDogY2ZnLnVw
bG9hZFVSTCB8fCAiL3VwbG9hZCINCgkJfTsNCgkJUGFyZW50LmFwcGx5KHRoaXMsIGFyZ3VtZW50
cyk7DQoJfQ0KCU1haW4uYXBwbHlUbyA9IGZ1bmN0aW9uKGEsIGIpIHsNCgkJaWYgKCFhIHx8ICJT
V0YuZXZlbnRIYW5kbGVyIiAhPSBhKQ0KCQkJcmV0dXJuIG51bGw7DQoJCXRyeSB7DQoJCQlyZXR1
cm4gU1dGUmVmZXJlbmNlLmV2ZW50SGFuZGxlci5hcHBseShTV0ZSZWZlcmVuY2UsIGIpOw0KCQl9
IGNhdGNoIChjKSB7DQoJCQlyZXR1cm4gbnVsbDsNCgkJfQ0KCX07DQoJTWFpbi5wcm90b3R5cGUg
PSB7DQoJCWNvbnN0cnVjdG9yIDogTWFpbiwNCgkJbmFtZSA6ICJ1cGxvYWRlciIsDQoJCWluaXRp
YWxpemVyIDogZnVuY3Rpb24oKSB7DQoJCQlzU3RyZWFtTWVzc2FnZXJJZCA9IHRoaXMuY29uZmln
Lm1lc3NhZ2VySWQ7DQoJCQl0aGlzLnN0YXJ0UGFuZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCh0aGlzLmNvbmZpZy5icm93c2VGaWxlSWQpOw0KCQkJLyoqIHRoZSBkZWZhdWx0IFVJICovDQoJ
CQlpZiAoIXRoaXMuY29uZmlnLmN1c3RvbWVyZWQpIHsNCgkJCQlmQWRkQ2xhc3ModGhpcy5zdGFy
dFBhbmVsLCAic3RyZWFtLWJyb3dzZS1maWxlcyIpOw0KCQkJCXRoaXMuc3RhcnRQYW5lbC5hcHBl
bmRDaGlsZChmQ3JlYXRlQ29udGVudEVsZSh0aGlzLmNvbmZpZy5icm93c2VGaWxlQnRuKSk7DQoJ
CQkJdmFyIGZpbGVzUXVldWVQYW5lbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKHRoaXMuY29u
ZmlnLmZpbGVzUXVldWVJZCk7DQoJCQkJZkFkZENsYXNzKGZpbGVzUXVldWVQYW5lbCwgInN0cmVh
bS1tYWluLXVwbG9hZC1ib3giKTsNCgkJCQl2YXIgZmlsZXNDb250YWluZXJJZCA9IGZHZW5lcmF0
ZUlkKCJmaWxlcy1jb250YWluZXIiKSwNCgkJCQkgICAgdG90YWxDb250YWluZXJJZCA9IGZHZW5l
cmF0ZUlkKCJ0b3RhbC1jb250YWluZXIiKTsNCgkJCQl2YXIgZmlsZXNRdWV1ZSA9IGZDcmVhdGVD
b250ZW50RWxlKHNGaWxlc0NvbnRhaW5lci5yZXBsYWNlKCIjZmlsZXNDb250YWluZXJJZCMiLCBm
aWxlc0NvbnRhaW5lcklkKS5yZXBsYWNlKCIjZmlsZXNRdWV1ZUhlaWdodCMiLCB0aGlzLmNvbmZp
Zy5maWxlc1F1ZXVlSGVpZ2h0KSksDQoJCQkJCXRvdGFsUXVldWUgPSBmQ3JlYXRlQ29udGVudEVs
ZShzVG90YWxDb250YWluZXIucmVwbGFjZSgiI3RvdGFsQ29udGFpbmVySWQjIiwgdG90YWxDb250
YWluZXJJZCkpOw0KCQkJCWZpbGVzUXVldWVQYW5lbC5hcHBlbmRDaGlsZChmaWxlc1F1ZXVlKTsN
CgkJCQlmaWxlc1F1ZXVlUGFuZWwuYXBwZW5kQ2hpbGQodG90YWxRdWV1ZSk7DQoJCQkJDQoJCQkJ
dGhpcy5jb250YWluZXJQYW5lbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGZpbGVzQ29udGFp
bmVySWQpOw0KCQkJCXRoaXMudG90YWxDb250YWluZXJQYW5lbCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKHRvdGFsQ29udGFpbmVySWQpOw0KCQkJCXRoaXMudGVtcGxhdGUgPSBzQ2VsbEZpbGVU
ZW1wbGF0ZTsNCgkJCX0NCgkJCQ0KCQkJdGhpcy5maWxlUHJvdmlkZXIgPSBuZXcgUHJvdmlkZXIo
dGhpcy5jb25maWcpOw0KCQkJdGhpcy5maWxlUHJvdmlkZXIucmVuZGVyKHRoaXMuc3RhcnRQYW5l
bCk7DQoJCQl0aGlzLmZpbGVQcm92aWRlci5vbigidXBsb2FkcHJvZ3Jlc3MiLCB0aGlzLnVwbG9h
ZFByb2dyZXNzLCB0aGlzKTsNCgkJCXRoaXMuZmlsZVByb3ZpZGVyLm9uKCJ1cGxvYWRjb21wbGV0
ZSIsIHRoaXMudXBsb2FkQ29tcGxldGUsIHRoaXMpOw0KCQkJdGhpcy5maWxlUHJvdmlkZXIub24o
InVwbG9hZGVycm9yIiwgdGhpcy51cGxvYWRFcnJvciwgdGhpcyk7DQoJCQl0aGlzLmZpbGVQcm92
aWRlci5vbigiZmlsZXNlbGVjdCIsIHRoaXMuZmlsZVNlbGVjdCwgdGhpcyk7DQoJCQlmQWRkRXZl
bnRMaXN0ZW5lcih3aW5kb3csICJiZWZvcmV1bmxvYWQiLCBmRXh0ZW5kKHRoaXMudW5sb2FkSGFu
ZGxlciwgdGhpcykpOw0KCQkJdGhpcy53YWl0aW5nID0gW107DQoJCQl0aGlzLnVwbG9hZGluZyA9
ICExOw0KCQkJdGhpcy50b3RhbEZpbGVTaXplID0gMDsNCgkJCXRoaXMudG90YWxVcGxvYWRlZFNp
emUgPSAwOw0KCQl9LA0KCQlhZGRTdHJlYW1UYXNrIDogZnVuY3Rpb24oYSkgew0KCQkJdmFyIGZp
bGVfaWQgPSBhLmdldCgiaWQiKSwgY2VsbF9maWxlID0gZkNyZWF0ZUNvbnRlbnRFbGUoIjxsaSBp
ZD0nIiArIGZpbGVfaWQgKyAiJyBjbGFzcz0nc3RyZWFtLWNlbGwtZmlsZSc+PC9saT4iKTsNCgkJ
CWNlbGxfZmlsZS5pbm5lckhUTUwgPSB0aGlzLnRlbXBsYXRlOw0KCQkJdGhpcy51cGxvYWRJbmZv
W2ZpbGVfaWRdID0gew0KCQkJCXVwbG9hZFRva2VuIDogIiIsDQoJCQkJdXBsb2FkQ29tcGxldGUg
OiAhMSwNCgkJCQlmaWxlIDogYSwNCgkJCQlkaXNhYmxlZCA6ICExLA0KCQkJCWFjdGl2ZWQgOiAh
MSwNCgkJCQlwcm9ncmVzc05vZGUgOiB0aGlzLmdldE5vZGUoInN0cmVhbS1wcm9jZXNzIiwgY2Vs
bF9maWxlKSwNCgkJCQljZWxsSW5mb3NOb2RlIDogdGhpcy5nZXROb2RlKCJzdHJlYW0tY2VsbC1p
bmZvcyIsIGNlbGxfZmlsZSkNCgkJCX07DQoJCQl0aGlzLnRvdGFsRmlsZVNpemUgKz0gdGhpcy51
cGxvYWRJbmZvW2ZpbGVfaWRdLmZpbGUuZ2V0KCJzaXplIik7DQoJCQlpZiAoIXRoaXMuY29uZmln
LmN1c3RvbWVyZWQpIHsNCgkJCQl0aGlzLmdldE5vZGUoInN0cmVhbS1maWxlLW5hbWUiLCBjZWxs
X2ZpbGUpLmdldEVsZW1lbnRzQnlUYWdOYW1lKCJzdHJvbmciKVswXS5pbm5lckhUTUwgPSBhLmdl
dCgibmFtZSIpOw0KCQkJCXRoaXMuY29udGFpbmVyUGFuZWwuYXBwZW5kQ2hpbGQoY2VsbF9maWxl
KTsNCgkJCQl0aGlzLnJlbmRlclVJKGZpbGVfaWQpOw0KCQkJCXRoaXMuYmluZFVJKGZpbGVfaWQp
Ow0KCQkJfQ0KCQkJLyoqIGRvIG5vdCBoaWRkZW4gdGhlIHVwbG9hZCBidXR0b24gKi8NCgkJCS8q
YlN0cmVhbWluZyA/IHRoaXMuc3RhcnRQYW5lbC5zdHlsZS5kaXNwbGF5ID0gIm5vbmUiIDogKHRo
aXMuc3RhcnRQYW5lbC5zdHlsZS5oZWlnaHQgPSAiMXB4IiwgdGhpcy5zdGFydFBhbmVsLnN0eWxl
LndpZHRoID0gIjFweCIpOyovDQoJCQl0aGlzLndhaXRpbmcucHVzaChmaWxlX2lkKTsNCgkJCXRo
aXMuY29uZmlnLmF1dG9VcGxvYWRpbmcgJiYgdGhpcy51cGxvYWQoZmlsZV9pZCk7DQoJCX0sDQoJ
CXJlbmRlclVJIDogZnVuY3Rpb24oZmlsZV9pZCkgew0KCQkJdmFyIHByb2dyZXNzTm9kZSA9IHRo
aXMudXBsb2FkSW5mb1tmaWxlX2lkXS5wcm9ncmVzc05vZGUsDQoJCQkJY2VsbEluZm9zTm9kZSA9
IHRoaXMudXBsb2FkSW5mb1tmaWxlX2lkXS5jZWxsSW5mb3NOb2RlLA0KCQkJCXNpemUgPSB0aGlz
LnVwbG9hZEluZm9bZmlsZV9pZF0uZmlsZS5nZXQoInNpemUiKSwNCgkJCQl0b3RhbCA9IHRoaXMu
Zm9ybWF0Qnl0ZXMoc2l6ZSk7DQoJCQl0aGlzLmdldE5vZGUoInN0cmVhbS1wcm9jZXNzLWJhciIs
IHByb2dyZXNzTm9kZSkuaW5uZXJIVE1MID0gIjxzcGFuIHN0eWxlPSd3aWR0aDowJTsnPjwvc3Bh
bj4iOw0KCQkJdGhpcy5nZXROb2RlKCJzdHJlYW0tcGVyY2VudCIsIHByb2dyZXNzTm9kZSkuaW5u
ZXJIVE1MID0gIjAlIjsNCgkJCXRoaXMuZ2V0Tm9kZSgic3RyZWFtLXNwZWVkIiwgY2VsbEluZm9z
Tm9kZSkuaW5uZXJIVE1MID0gIi0iOw0KCQkJdGhpcy5nZXROb2RlKCJzdHJlYW0tcmVtYWluLXRp
bWUiLCBjZWxsSW5mb3NOb2RlKS5pbm5lckhUTUwgPSAiLS06LS06LS0iOw0KCQkJdGhpcy5nZXRO
b2RlKCJzdHJlYW0tdXBsb2FkZWQiLCBjZWxsSW5mb3NOb2RlKS5pbm5lckhUTUwgPSAiMC8iICsg
dG90YWw7DQoJCQl2YXIgX3RvdGFsID0gdGhpcy5mb3JtYXRCeXRlcyh0aGlzLnRvdGFsRmlsZVNp
emUpOw0KCQkJdGhpcy5nZXROb2RlKCJfc3RyZWFtLXRvdGFsLXNpemUiLCB0aGlzLnRvdGFsQ29u
dGFpbmVyUGFuZWwpLmlubmVySFRNTCA9IF90b3RhbDsNCgkJfSwNCgkJYmluZFVJIDogZnVuY3Rp
b24oZmlsZV9pZCkgew0KCQkJdmFyIGIgPSB0aGlzLnVwbG9hZEluZm9bZmlsZV9pZF0ucHJvZ3Jl
c3NOb2RlLCBjYW5jZWxCdG4gPSB0aGlzLmdldE5vZGUoInN0cmVhbS1jYW5jZWwiLCBiKTsNCgkJ
CXRoaXMuY2FuY2VsQnRuSGFuZGxlciA9IGZFeHRlbmQodGhpcy5jYW5jZWxVcGxvYWRIYW5kbGVy
LCB0aGlzLCB7dHlwZSA6ICJjbGljayIsCW5vZGVJZCA6IGZpbGVfaWR9KTsNCgkJCWZBZGRFdmVu
dExpc3RlbmVyKGNhbmNlbEJ0biwgImNsaWNrIiwgdGhpcy5jYW5jZWxCdG5IYW5kbGVyKTsNCgkJ
fSwNCgkJY29tcGxldGVVcGxvYWQgOiBmdW5jdGlvbihpbmZvKSB7DQoJCQl0aGlzLmdldCgib25D
b21wbGV0ZSIpID8gdGhpcy5nZXQoIm9uQ29tcGxldGUiKShpbmZvKSA6IHRoaXMub25Db21wbGV0
ZShpbmZvKTsNCgkJCXRoaXMud2FpdGluZy5sZW5ndGggPT0gMCAmJiAodGhpcy5nZXQoIm9uUXVl
dWVDb21wbGV0ZSIpID8gdGhpcy5nZXQoIm9uUXVldWVDb21wbGV0ZSIpKGluZm8ubXNnKSA6IHRo
aXMub25RdWV1ZUNvbXBsZXRlKGluZm8ubXNnKSk7DQoJCQl0aGlzLmNvbmZpZy5hdXRvUmVtb3Zl
Q29tcGxldGVkICYmIChpbmZvID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaW5mby5pZCksIGlu
Zm8ucGFyZW50Tm9kZSAmJiBpbmZvLnBhcmVudE5vZGUucmVtb3ZlQ2hpbGQoaW5mbykpOw0KCQkJ
dGhpcy51cGxvYWRpbmcgPSAhMTsNCgkJCXRoaXMudXBsb2FkKCk7DQoJCX0sDQoJCW9uU2VsZWN0
IDogZnVuY3Rpb24obGlzdCkgew0KCQkJZlNob3dNZXNzYWdlKCJzZWxlY3RlZCBmaWxlczogIiAr
IGxpc3QubGVuZ3RoKTsNCgkJfSwNCgkJb25GaWxlQ291bnRFeGNlZWQgOiBmdW5jdGlvbihzZWxl
Y3RlZCwgbGltaXQpIHsNCgkJCWZTaG93TWVzc2FnZSgiRmlsZSBjb3VudHM6IiArIHNlbGVjdGVk
ICsgIiwgYnV0IGxpbWl0ZWQ6IiArIGxpbWl0LCB0cnVlKTsNCgkJfSwNCgkJb25NYXhTaXplRXhj
ZWVkIDogZnVuY3Rpb24oZmlsZSkgew0KCQkJZlNob3dNZXNzYWdlKCJGaWxlOiIgKyBmaWxlLm5h
bWUgKyAiIHNpemUgaXM6IiArIGZpbGUuc2l6ZSArIiBFeGNlZWQgbGltaXRlZDoiICsgZmlsZS5s
aW1pdFNpemUsIHRydWUpOw0KCQl9LA0KCQlvbkV4dE5hbWVNaXNtYXRjaDogZnVuY3Rpb24oZmls
ZSkgew0KCQkJZlNob3dNZXNzYWdlKCJBbGxvdyBleHQgbmFtZTogWyIgKyBmaWxlLmZpbHRlcnMu
dG9TdHJpbmcoKSArICJdLCBub3QgZm9yICIgKyBmaWxlLm5hbWUsIHRydWUpOw0KCQl9LA0KCQlv
bkFkZFRhc2s6IGZ1bmN0aW9uKGZpbGUpIHsNCgkJCWZTaG93TWVzc2FnZSgiQWRkIHRvIHRhc2sg
PDwgbmFtZTogWyIgKyBmaWxlLm5hbWUpOw0KCQl9LA0KCQlvbkNhbmNlbCA6IGZ1bmN0aW9uKGZp
bGUpIHsNCgkJCWZTaG93TWVzc2FnZSgiQ2FuY2VsZWQ6ICIgKyBmaWxlLm5hbWUpOw0KCQl9LA0K
CQlvblN0b3AgOiBmdW5jdGlvbigpIHsNCgkJCWZTaG93TWVzc2FnZSgiU3RvcHBlZCEiKTsNCgkJ
fSwNCgkJb25DYW5jZWxBbGwgOiBmdW5jdGlvbihudW1iZXJzKSB7DQoJCQlmU2hvd01lc3NhZ2Uo
bnVtYmVycyArICIgZmlsZXMgQ2FuY2VsZWQhICIpOw0KCQl9LA0KCQlvbkNvbXBsZXRlIDogZnVu
Y3Rpb24oZmlsZSkgew0KCQkJZlNob3dNZXNzYWdlKCJGaWxlOiIgKyBmaWxlLm5hbWUgKyAiLCBT
aXplOiIgKyBmaWxlLnNpemUgKyAiIG9uQ29tcGxldGUJW09LXSIpOw0KCQl9LA0KCQlvblF1ZXVl
Q29tcGxldGUgOiBmdW5jdGlvbihtc2cpIHsNCgkJCWZTaG93TWVzc2FnZSgib25RdWV1ZUNvbXBs
ZXRlKG1zZzogIittc2crIikJLS0tPT0+CQlbT0tdIik7DQoJCX0sDQoJCW9uVXBsb2FkRXJyb3Ig
OiBmdW5jdGlvbihzdGF0dXMsIG1zZykgew0KCQkJZlNob3dNZXNzYWdlKCJFcnJvciBPY2N1ci4g
IFN0YXR1czoiICsgc3RhdHVzICsgIiwgTWVzc2FnZTogIiArIG1zZywgdHJ1ZSk7DQoJCX0sDQoJ
CWRpc2FibGUgOiBmdW5jdGlvbigpIHsNCgkJCXRoaXMuZmlsZVByb3ZpZGVyLnNldCgiZW5hYmxl
ZCIsICExKSwgdGhpcy5maWxlUHJvdmlkZXIudHJpZ2dlckVuYWJsZWQoKSwgZkFkZENsYXNzKHRo
aXMuc3RhcnRQYW5lbC5jaGlsZHJlblswXSwgInN0cmVhbS1kaXNhYmxlLWJyb3dzZXIiKSwgZkFk
ZENsYXNzKHRoaXMuc3RhcnRQYW5lbCwgImRpc2FibGVkIik7DQoJCX0sDQoJCWVuYWJsZSA6IGZ1
bmN0aW9uKCkgew0KCQkJdGhpcy5maWxlUHJvdmlkZXIuc2V0KCJlbmFibGVkIiwgITApLCB0aGlz
LmZpbGVQcm92aWRlci50cmlnZ2VyRW5hYmxlZCgpLCBmUmVtb3ZlQ2xhc3ModGhpcy5zdGFydFBh
bmVsLmNoaWxkcmVuWzBdLCAic3RyZWFtLWRpc2FibGUtYnJvd3NlciIpLCBmUmVtb3ZlQ2xhc3Mo
dGhpcy5zdGFydFBhbmVsLCAiZGlzYWJsZWQiKTsNCgkJfSwNCgkJc3RvcCA6IGZ1bmN0aW9uKCkg
ew0KCQkJaWYgKCF0aGlzLnVwbG9hZGluZykgcmV0dXJuIGZhbHNlOw0KCQkJdGhpcy51cGxvYWRp
bmcgPSAhMTsNCgkJCXZhciBmaWxlcyA9IHRoaXMudXBsb2FkSW5mbywgbnVtYmVyID0gMDsNCgkJ
CS8qKiBjYW5jZWwgdGhlIHVuZmluaXNoZWQgdXBsb2FkaW5nIGZpbGVzICovDQoJCQlmb3IodmFy
IGZpbGVJZCBpbiBmaWxlcykgew0KCQkJCS8qKiBhZGQgdGhlIGBmaWxlX2lkYCB0byBgd2FpdGlu
Z2AgQCBpbmRleCBvZiAwICovDQoJCQkJaWYgKCFmaWxlc1tmaWxlSWRdLnVwbG9hZENvbXBsZXRl
KSB7DQoJCQkJCXRoaXMuY2FuY2VsT25lKGZpbGVJZCwgdHJ1ZSkgJiYgdGhpcy51cGxvYWRJbmZv
W2ZpbGVJZF0gJiYgdGhpcy53YWl0aW5nLnVuc2hpZnQoZmlsZUlkKTsNCgkJCQkJYnJlYWs7CQ0K
CQkJCX0NCgkJCX0NCgkJCXRoaXMuZ2V0KCJvblN0b3AiKSA/IHRoaXMuZ2V0KCJvblN0b3AiKSgp
IDogdGhpcy5vblN0b3AoKTsNCgkJfSwNCgkJY2FuY2VsIDogZnVuY3Rpb24oKSB7DQoJCQl0aGlz
LnVwbG9hZGluZyA9ICExOw0KCQkJdmFyIGZpbGVzID0gdGhpcy51cGxvYWRJbmZvLCBudW1iZXIg
PSAwOw0KCQkJLyoqIGNhbmNlbCB0aGUgdW5maW5pc2hlZCB1cGxvYWRpbmcgZmlsZXMgKi8NCgkJ
CWZvcih2YXIgZmlsZUlkIGluIGZpbGVzKQ0KCQkJCSFmaWxlc1tmaWxlSWRdLnVwbG9hZENvbXBs
ZXRlICYmICgrK251bWJlcikgJiYgdGhpcy5jYW5jZWxPbmUoZmlsZUlkKTsNCgkJCXRoaXMuZ2V0
KCJvbkNhbmNlbEFsbCIpID8gdGhpcy5nZXQoIm9uQ2FuY2VsQWxsIikobnVtYmVyKSA6IHRoaXMu
b25DYW5jZWxBbGwobnVtYmVyKTsNCgkJfSwNCgkJY2FuY2VsT25lIDogZnVuY3Rpb24oZmlsZV9p
ZCwgc3RvcHBpbmcpIHsNCgkJCXZhciBwcm92aWRlciA9IHRoaXMudXBsb2FkSW5mb1tmaWxlX2lk
XS5maWxlLCBhY3RpdmVkID0gdGhpcy51cGxvYWRJbmZvW2ZpbGVfaWRdLmFjdGl2ZWQ7DQoJCQlw
cm92aWRlciAmJiBwcm92aWRlci5jYW5jZWxVcGxvYWQgJiYgcHJvdmlkZXIuY2FuY2VsVXBsb2Fk
KCk7DQoJCQlpZiAoISFzdG9wcGluZykgcmV0dXJuIHRydWU7DQoJCQkNCgkJCXZhciB0b3RhbFNp
emUgPSB0aGlzLnRvdGFsRmlsZVNpemUgLSB0aGlzLnVwbG9hZEluZm9bZmlsZV9pZF0uZmlsZS5j
b25maWcuc2l6ZSwgaW5mbyA9IHsNCgkJCQlpZDogICBmaWxlX2lkLA0KCQkJCW5hbWU6IHRoaXMu
dXBsb2FkSW5mb1tmaWxlX2lkXS5maWxlLmNvbmZpZy5uYW1lLA0KCQkJCXNpemU6IHRoaXMudXBs
b2FkSW5mb1tmaWxlX2lkXS5maWxlLmNvbmZpZy5zaXplLA0KCQkJCXRvdGFsU2l6ZTogdG90YWxT
aXplLA0KCQkJCWZvcm1hdFRvdGFsU2l6ZTogdGhpcy5mb3JtYXRCeXRlcyh0b3RhbFNpemUpLA0K
CQkJCXRvdGFsTG9hZGVkOiB0aGlzLnRvdGFsVXBsb2FkZWRTaXplLA0KCQkJCWZvcm1hdFRvdGFs
TG9hZGVkOiB0aGlzLmZvcm1hdEJ5dGVzKHRoaXMudG90YWxVcGxvYWRlZFNpemUpLA0KCQkJCXRv
dGFsUGVyY2VudDogdG90YWxTaXplID09IDAgPyAwIDogdGhpcy50b3RhbFVwbG9hZGVkU2l6ZSAq
IDEwMDAwIC8gdG90YWxTaXplIC8gMTAwDQoJCQl9Ow0KCQkJMTAwID4gaW5mby50b3RhbFBlcmNl
bnQgJiYgKGluZm8udG90YWxQZXJjZW50ID0gcGFyc2VGbG9hdChpbmZvLnRvdGFsUGVyY2VudCku
dG9GaXhlZCgyKSk7DQoJCQkNCgkJCXRoaXMuZ2V0KCJvbkNhbmNlbCIpID8gdGhpcy5nZXQoIm9u
Q2FuY2VsIikoaW5mbykgOiB0aGlzLm9uQ2FuY2VsKGluZm8pOw0KCQkJdGhpcy51cGxvYWRJbmZv
W2ZpbGVfaWRdICYmIGRlbGV0ZSB0aGlzLnVwbG9hZEluZm9bZmlsZV9pZF07DQoJCQlmUmVtb3Zl
RXZlbnRMaXN0ZW5lcihkb2N1bWVudCwgImNsaWNrIiwgdGhpcy5jYW5jZWxCdG5IYW5kbGVyKTsN
CgkJCSF0aGlzLmNvbmZpZy5jdXN0b21lcmVkICYmIHRoaXMuY29udGFpbmVyUGFuZWwucmVtb3Zl
Q2hpbGQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoZmlsZV9pZCkpOw0KCQkJaWYgKGFjdGl2ZWQp
IHsNCgkJCQl0aGlzLnVwbG9hZGluZyA9ICExOw0KCQkJCXRoaXMudXBsb2FkKCk7DQoJCQl9IGVs
c2Ugew0KCQkJCWZvcih2YXIgaSBpbiB0aGlzLndhaXRpbmcpDQoJCQkJCWlmICh0aGlzLndhaXRp
bmdbaV0gPT09IGZpbGVfaWQpDQoJCQkJCQl0aGlzLndhaXRpbmcuc3BsaWNlKGksIDEpOw0KCQkJ
fQ0KCQkJdmFyIHNpemUgPSBwcm92aWRlci5jb25maWcuc2l6ZTsNCgkJCXRoaXMudG90YWxGaWxl
U2l6ZSAtPSBzaXplOw0KCQkJdmFyIF9sb2FkZWQgPSB0aGlzLmZvcm1hdEJ5dGVzKHRoaXMudG90
YWxVcGxvYWRlZFNpemUpOw0KCQkJdmFyIHBlcmNlbnQgPSB0aGlzLnRvdGFsVXBsb2FkZWRTaXpl
ICogMTAwMDAgLyB0aGlzLnRvdGFsRmlsZVNpemUgLyAxMDA7DQoJCQkxMDAgPiBwZXJjZW50ICYm
IChwZXJjZW50ID0gcGFyc2VGbG9hdChwZXJjZW50KS50b0ZpeGVkKDIpKTsNCgkJCWlmICh0aGlz
LnRvdGFsRmlsZVNpemUgPT09IDApDQoJCQkJcGVyY2VudCA9IDEwMDsNCgkJCQkNCgkJCWlmICgh
dGhpcy5jb25maWcuY3VzdG9tZXJlZCkgew0KCQkJCXZhciBfdG90YWwgPSB0aGlzLmZvcm1hdEJ5
dGVzKHRoaXMudG90YWxGaWxlU2l6ZSk7DQoJCQkJdGhpcy5nZXROb2RlKCJfc3RyZWFtLXRvdGFs
LXNpemUiLCB0aGlzLnRvdGFsQ29udGFpbmVyUGFuZWwpLmlubmVySFRNTCA9IF90b3RhbDsNCgkJ
CQl0aGlzLmdldE5vZGUoIl9zdHJlYW0tdG90YWwtdXBsb2FkZWQiLCB0aGlzLnRvdGFsQ29udGFp
bmVyUGFuZWwpLmlubmVySFRNTCA9IF9sb2FkZWQ7DQoJCQkJdGhpcy5nZXROb2RlKCJzdHJlYW0t
cGVyY2VudCIsIHRoaXMudG90YWxDb250YWluZXJQYW5lbCkuaW5uZXJIVE1MID0gcGVyY2VudCAr
ICIlIjsNCgkJCQl0aGlzLmdldE5vZGUoInN0cmVhbS1wcm9jZXNzLWJhciIsIHRoaXMudG90YWxD
b250YWluZXJQYW5lbCkuaW5uZXJIVE1MID0gJzxzcGFuIHN0eWxlPSJ3aWR0aDogJytwZXJjZW50
KyclOyI+PC9zcGFuPic7DQoJCQkJDQoJCQkJLyoqKiBUT0RPOiB0aGlzIGNvZGUgd2lsbCBiZSBy
ZW1vdmVkIGluIHRoZSBmdXR1cmUuDQoJCQkJYlN0cmVhbWluZyA/IHRoaXMuc3RhcnRQYW5lbC5z
dHlsZS5kaXNwbGF5ID0gImJsb2NrIg0KCQkJCQk6ICh0aGlzLnN0YXJ0UGFuZWwuc3R5bGUuaGVp
Z2h0ID0gImF1dG8iLCB0aGlzLnN0YXJ0UGFuZWwuc3R5bGUud2lkdGggPSAiOTcwcHgiKTsqLw0K
CQkJfQ0KCQl9LA0KCQljYW5jZWxVcGxvYWRIYW5kbGVyIDogZnVuY3Rpb24oZXZlbnQsIGIpIHsN
CgkJCXZhciBjID0gZXZlbnQgfHwgd2luZG93LmV2ZW50LCBpZCA9IGIubm9kZUlkLCBzZWxmID0g
dGhpczsNCgkJCXRoaXMucHJldmVudERlZmF1bHQoYyk7DQoJCQl0aGlzLnN0b3BQcm9wYWdhdGlv
bihjKTsNCgkJCWlmICh0aGlzLnVwbG9hZEluZm9baWRdLmRpc2FibGVkKQ0KCQkJCXJldHVybiAh
MTsNCgkJCXRoaXMudXBsb2FkSW5mb1tpZF0gJiYgIXRoaXMudXBsb2FkSW5mb1tpZF0udXBsb2Fk
Q29tcGxldGU7DQoJCQl0aGlzLmNhbmNlbE9uZShpZCk7DQoJCX0sDQoJCXVubG9hZEhhbmRsZXIg
OiBmdW5jdGlvbihldnQpIHsNCgkJCXZhciBldnQgPSBldnQgfHwgd2luZG93LmV2ZW50Ow0KCQkJ
aWYgKHRoaXMud2FpdGluZy5sZW5ndGggPiAwKQ0KCQkJCXJldHVybiBldnQucmV0dXJuVmFsdWUg
PSAiXHU2MEE4XHU2QjYzXHU1NzI4XHU0RTBBXHU0RjIwXHU2NTg3XHU0RUY2XHVGRjBDXHU1MTcz
XHU5NUVEXHU2QjY0XHU5ODc1XHU5NzYyXHU1QzA2XHU0RjFBXHU0RTJEXHU2NUFEXHU0RTBBXHU0
RjIwXHVGRjBDXHU1RUZBXHU4QkFFXHU2MEE4XHU3QjQ5XHU1Rjg1XHU0RTBBXHU0RjIwXHU1QjhD
XHU2MjEwXHU1NDBFXHU1MThEXHU1MTczXHU5NUVEXHU2QjY0XHU5ODc1XHU5NzYyIjsNCgkJfSwN
CgkJdXBsb2FkIDogZnVuY3Rpb24oaW5kZXgpIHsNCgkJCWlmKHRoaXMudXBsb2FkaW5nKSByZXR1
cm47DQoJCQlpbmRleCA9IHRoaXMud2FpdGluZy5zaGlmdCgpOw0KCQkJaWYoaW5kZXggPT0gbnVs
bCkgcmV0dXJuOw0KCQkJdGhpcy51cGxvYWRpbmcgPSAhMDsNCgkJCQ0KCQkJdGhpcy51cGxvYWRJ
bmZvW2luZGV4XS5hY3RpdmVkID0gITA7DQoJCQl2YXIgZmlsZSA9IHRoaXMudXBsb2FkSW5mb1tp
bmRleF0uZmlsZSwgc2VsZiA9IHRoaXM7DQoJCQl2YXIgZnJtVXBsb2FkVVJMID0gdGhpcy5nZXQo
ImZybVVwbG9hZFVSTCIpOw0KCQkJdmFyIHVwbG9hZFVSTCA9IHRoaXMuZ2V0KCJ1cGxvYWRVUkwi
KTsNCgkJCS8qKiByZXF1ZXN0IHRoZSBzZXJ2ZXIgdG8gZmlndXJlIG91dCB3aGF0J3MgdGhlIHRv
a2VuIGZvciB0aGUgZmlsZTogKi8NCgkJCXZhciB4aHIgPSB3aW5kb3cuWE1MSHR0cFJlcXVlc3Qg
PyBuZXcgWE1MSHR0cFJlcXVlc3QgOiBuZXcgQWN0aXZlWE9iamVjdCgiTWljcm9zb2Z0LlhNTEhU
VFAiKTsNCgkJCQ0KCQkJdmFyIHZhcnMgPSB7DQoJCQkJbmFtZToJIGZpbGUuZ2V0KCduYW1lJyks
DQoJCQkJdHlwZTogZmlsZS5nZXQoJ3R5cGUnKSwNCgkJCQlzaXplOiBmaWxlLmdldCgnc2l6ZScp
LA0KCQkJCW1vZGlmaWVkOiBmaWxlLmdldCgiZGF0ZU1vZGlmaWVkIikgKyAiIg0KCQkJfTsgDQoJ
CQl2YXIgdG9rZW5VcmwgPSBmQWRkVmFycyh2YXJzLCB0aGlzLmdldCgidG9rZW5VUkwiKSkgKyAi
JiIgKyBmR2V0UmFuZG9tKCk7DQoJCQl4aHIub3BlbigiR0VUIiwgdG9rZW5VcmwsICEwKTsNCgkJ
CS8qKiBJRTcsOCDlhbzlrrkqLw0KCQkJeGhyLm9ucmVhZHlzdGF0ZWNoYW5nZSA9IGZ1bmN0aW9u
KCkgew0KCQkJICAgIGlmICh4aHIucmVhZHlTdGF0ZSAhPSA0IHx8IHhoci5zdGF0dXMgPCAyMDAp
DQoJCQkgICAgICAgIHJldHVybiBmYWxzZTsNCgkJCSAgICANCgkJCSAgICB2YXIgdG9rZW4sIHNl
cnZlcjsNCgkJCQl0cnkgew0KCQkJCQl0cnkgew0KCQkJCQkJdG9rZW4gPSBldmFsKCIoIiArIHho
ci5yZXNwb25zZVRleHQgKyAiKSIpLnRva2VuOw0KCQkJCQkJc2VydmVyID0gZXZhbCgiKCIgKyB4
aHIucmVzcG9uc2VUZXh0ICsgIikiKS5zZXJ2ZXI7DQoJCQkJCX0gY2F0Y2goZSkge30NCgkJCQkJ
aWYgKHRva2VuKSB7DQoJCQkJCQlpZihzZXJ2ZXIgIT0gbnVsbCAmJiBzZXJ2ZXIgIT0gIiIpIHsN
CgkJCQkJCQlmcm1VcGxvYWRVUkwgPSBzZXJ2ZXIgKyBmcm1VcGxvYWRVUkw7DQoJCQkJCQkJdXBs
b2FkVVJMID0gc2VydmVyICsgdXBsb2FkVVJMOw0KCQkJCQkJfQ0KCQkJCQkJYlN0cmVhbWluZyAm
JiBiRmlsZVNsaWNlID8gKHNlbGYudXBsb2FkSW5mb1tpbmRleF0uc2VydmVyQWRkcmVzcyA9IHNl
cnZlciwNCgkJCQkJCQkJCQlzZWxmLnVwbG9hZEZpbGUoZmlsZSwgdXBsb2FkVVJMLCB0b2tlbiwg
InJlc3VtZVVwbG9hZCIpKQ0KCQkJCQkJCQk6IHNlbGYudXBsb2FkRmlsZShmaWxlLCBmcm1VcGxv
YWRVUkwsIHRva2VuLCAiZm9ybVVwbG9hZCIpOw0KCQkJCQl9IGVsc2Ugew0KCQkJCQkJLyoqIG5v
dCBmb3VuZCBhbnkgdG9rZW4gKi8NCgkJCQkJCXNlbGYuY2FuY2VsT25lKGluZGV4KTsNCgkJCQkJ
CXZhciBtc2cgPSAiXHU1MjFCXHU1RUZBXHU0RTBBXHU0RjIwXHU0RUZCXHU1MkExXHU1OTMxXHU4
RDI1W3Rva2VuVVJMPSIgKyBzZWxmLmdldCgidG9rZW5VUkwiKSArICJdLFx1NzJCNlx1NjAwMVx1
NzgwMToiICsgeGhyLnN0YXR1czsNCgkJCQkJCWZTaG93TWVzc2FnZShtc2csIHRydWUpOw0KCQkJ
CQl9DQoJCQkJfSBjYXRjaChlKSB7DQoJCQkJCS8qKiBzdHJlYW1pbmcsIHN3ZiwgcmVzdW1lIG1l
dGhvZHMgYWxsIGZhaWxlZCwgbm8gbW9yZSB0cnkgICovDQoJCQkJfQ0KCQkJfQ0KCQkJd2luZG93
LlhNTEh0dHBSZXF1ZXN0ICYmICh4aHIub25lcnJvciA9IGZ1bmN0aW9uKCkgew0KCQkJCXNlbGYu
Y2FuY2VsT25lKGluZGV4KTsNCgkJCQl2YXIgbXNnID0gIlx1NTIxQlx1NUVGQVx1NEUwQVx1NEYy
MFx1NEVGQlx1NTJBMVx1NTkzMVx1OEQyNSxcdTcyQjZcdTYwMDFcdTc4MDE6IiArIHhoci5zdGF0
dXMgKyAiLFx1OEJGN1x1NjhDMFx1NkQ0Qlx1N0Y1MVx1N0VEQy4uLiI7DQoJCQkJZlNob3dNZXNz
YWdlKG1zZywgdHJ1ZSk7DQoJCQl9KTsNCgkJCXhoci5zZW5kKCk7DQoJCX0sDQoJCXVwbG9hZEZp
bGUgOiBmdW5jdGlvbihmaWxlLCB1cmwsIHRva2VuLCBtZXRob2QpIHsNCgkJCXZhciB0b2tlbiA9
IHsNCgkJCQl0b2tlbiA6IHRva2VuLA0KCQkJCWNsaWVudCA6IG1ldGhvZCA9PSAiZm9ybVVwbG9h
ZCIgPyAiZm9ybSIgOiAiaHRtbDUiDQoJCQl9Ow0KCQkJdXJsID0gdXJsIHx8ICIiOw0KCQkJbWV0
aG9kICYmIGZpbGUgaW5zdGFuY2VvZiBTdHJlYW1VcGxvYWRlciAmJiBmaWxlLnNldCgidXBsb2Fk
TWV0aG9kIiwgbWV0aG9kKTsNCgkJCXRoaXMuZmlsZVByb3ZpZGVyLnVwbG9hZChmaWxlLCB1cmws
IHRva2VuKTsNCgkJfSwNCgkJdXBsb2FkUHJvZ3Jlc3MgOiBmdW5jdGlvbihhKSB7DQoJCQl2YXIg
aWQgPSBhLnRhcmdldC5nZXQoImlkIiksIHBlcmNlbnQgPSBNYXRoLm1pbig5OS45OSwgYS5wZXJj
ZW50TG9hZGVkKSwNCgkJCQl0b3RhbFBlcmNlbnQgPSAodGhpcy50b3RhbFVwbG9hZGVkU2l6ZSAr
IGEuYnl0ZXNMb2FkZWQpICogMTAwMDAgLyB0aGlzLnRvdGFsRmlsZVNpemUgLyAxMDAsIHRvdGFs
UGVyY2VudCA9IE1hdGgubWluKDk5Ljk5LCB0b3RhbFBlcmNlbnQpOw0KCQkJMTAwID4gdG90YWxQ
ZXJjZW50ICYmICh0b3RhbFBlcmNlbnQgPSBwYXJzZUZsb2F0KHRvdGFsUGVyY2VudCkudG9GaXhl
ZCgyKSk7CQ0KCQkJDQoJCQlpZiAoIXRoaXMudXBsb2FkSW5mb1tpZF0pIHJldHVybiBmYWxzZTsN
CgkJCWlmICh0aGlzLmNvbmZpZy5jdXN0b21lcmVkKSB7DQoJCQkJdmFyIGluZm8gPSB7DQoJCQkJ
CWlkOiAgICAgICAgICAgICAgICAgaWQsDQoJCQkJCWxvYWRlZDogICAgICAgICAgICAgYS5ieXRl
c0xvYWRlZCwNCgkJCQkJZm9ybWF0TG9hZGVkOiAgICAgICB0aGlzLmZvcm1hdEJ5dGVzKGEuYnl0
ZXNMb2FkZWQpLA0KCQkJCQlzcGVlZDogICAgICAgICAgICAgIGEuYnl0ZXNTcGVlZCwNCgkJCQkJ
Zm9ybWF0U3BlZWQ6ICAgICAgICB0aGlzLmZvcm1hdFNwZWVkKGEuYnl0ZXNTcGVlZCksDQoJCQkJ
CXNpemU6ICAgICAgICAgICAgICAgYS5ieXRlc1RvdGFsLA0KCQkJCQlmb3JtYXRTaXplOiAgICAg
ICAgIHRoaXMuZm9ybWF0Qnl0ZXMoYS5ieXRlc1RvdGFsKSwNCgkJCQkJcGVyY2VudDogICAgICAg
ICAgICBwZXJjZW50LA0KCQkJCQl0aW1lTGVmdDogICAgICAgICAgIGEucmVtYWluVGltZSwNCgkJ
CQkJZm9ybWF0VGltZUxlZnQ6ICAgICB0aGlzLmZvcm1hdFRpbWUoYS5yZW1haW5UaW1lKSwNCgkJ
CQkJdG90YWxTaXplOiAgICAgICAgICB0aGlzLnRvdGFsRmlsZVNpemUsDQoJCQkJCWZvcm1hdFRv
dGFsU2l6ZTogICAgdGhpcy5mb3JtYXRCeXRlcyh0aGlzLnRvdGFsRmlsZVNpemUpLA0KCQkJCQl0
b3RhbExvYWRlZDogICAgICAgIHRoaXMudG90YWxVcGxvYWRlZFNpemUgKyBhLmJ5dGVzTG9hZGVk
LA0KCQkJCQlmb3JtYXRUb3RhbExvYWRlZDogIHRoaXMuZm9ybWF0Qnl0ZXModGhpcy50b3RhbFVw
bG9hZGVkU2l6ZSArIGEuYnl0ZXNMb2FkZWQpLA0KCQkJCQl0b3RhbFBlcmNlbnQ6ICAgICAgIHRv
dGFsUGVyY2VudA0KCQkJCX07DQoJCQkJdGhpcy5nZXQoIm9uVXBsb2FkUHJvZ3Jlc3MiKSAmJiB0
aGlzLmdldCgib25VcGxvYWRQcm9ncmVzcyIpKGluZm8pOw0KCQkJCXJldHVybiBmYWxzZTsNCgkJ
CX0NCgkJCQ0KCQkJdmFyIHByb2dyZXNzTm9kZSA9IHRoaXMudXBsb2FkSW5mb1tpZF0ucHJvZ3Jl
c3NOb2RlLA0KCQkJCWNlbGxJbmZvc05vZGUgPSB0aGlzLnVwbG9hZEluZm9baWRdLmNlbGxJbmZv
c05vZGUsIGJ5dGVzTG9hZGVkID0gYS5ieXRlc0xvYWRlZCwNCgkJCQljID0gdGhpcy5mb3JtYXRT
cGVlZChhLmJ5dGVzU3BlZWQpLCBsb2FkZWQgPSB0aGlzLmZvcm1hdEJ5dGVzKGJ5dGVzTG9hZGVk
KSwNCgkJCQl0b3RhbCA9IHRoaXMuZm9ybWF0Qnl0ZXMoYS5ieXRlc1RvdGFsKSwgX3JlbWFpblRp
bWUgPSB0aGlzLmZvcm1hdFRpbWUoYS5yZW1haW5UaW1lKSwNCgkJCQlhID0gTWF0aC5taW4oOTku
OTksIGEucGVyY2VudExvYWRlZCk7DQoJCQkxMDAgPiBhICYmIChhID0gcGFyc2VGbG9hdChhKS50
b0ZpeGVkKDIpKTsNCgkJCXRoaXMuZ2V0Tm9kZSgic3RyZWFtLXByb2Nlc3MtYmFyIiwgcHJvZ3Jl
c3NOb2RlKS5pbm5lckhUTUwgPSAiPHNwYW4gc3R5bGU9J3dpZHRoOiIrYSsiJTsnPjwvc3Bhbj4i
Ow0KCQkJdGhpcy5nZXROb2RlKCJzdHJlYW0tcGVyY2VudCIsIHByb2dyZXNzTm9kZSkuaW5uZXJI
VE1MID0gYSArICIlIjsNCgkJCXRoaXMuZ2V0Tm9kZSgic3RyZWFtLXNwZWVkIiwgY2VsbEluZm9z
Tm9kZSkuaW5uZXJIVE1MID0gYzsNCgkJCWlmIChfcmVtYWluVGltZSkNCgkJCQl0aGlzLmdldE5v
ZGUoInN0cmVhbS1yZW1haW4tdGltZSIsIGNlbGxJbmZvc05vZGUpLmlubmVySFRNTCA9IF9yZW1h
aW5UaW1lOw0KCQkJdGhpcy5nZXROb2RlKCJzdHJlYW0tdXBsb2FkZWQiLCBjZWxsSW5mb3NOb2Rl
KS5pbm5lckhUTUwgPSBsb2FkZWQgKyAiLyIgKyB0b3RhbDsNCgkJCQ0KCQkJdmFyIF9sb2FkZWQg
PSB0aGlzLmZvcm1hdEJ5dGVzKHRoaXMudG90YWxVcGxvYWRlZFNpemUgKyBieXRlc0xvYWRlZCk7
DQoJCQl2YXIgcGVyY2VudCA9ICh0aGlzLnRvdGFsVXBsb2FkZWRTaXplICsgYnl0ZXNMb2FkZWQp
ICogMTAwMDAgLyB0aGlzLnRvdGFsRmlsZVNpemUgLyAxMDAsIHBlcmNlbnQgPSBNYXRoLm1pbig5
OS45OSwgcGVyY2VudCk7DQoJCQkxMDAgPiBwZXJjZW50ICYmIChwZXJjZW50ID0gcGFyc2VGbG9h
dChwZXJjZW50KS50b0ZpeGVkKDIpKTsNCgkJCXRoaXMuZ2V0Tm9kZSgiX3N0cmVhbS10b3RhbC11
cGxvYWRlZCIsIHRoaXMudG90YWxDb250YWluZXJQYW5lbCkuaW5uZXJIVE1MID0gX2xvYWRlZDsN
CgkJCXRoaXMuZ2V0Tm9kZSgic3RyZWFtLXBlcmNlbnQiLCB0aGlzLnRvdGFsQ29udGFpbmVyUGFu
ZWwpLmlubmVySFRNTCA9IHBlcmNlbnQgKyAiJSI7DQoJCQl0aGlzLmdldE5vZGUoInN0cmVhbS1w
cm9jZXNzLWJhciIsIHRoaXMudG90YWxDb250YWluZXJQYW5lbCkuaW5uZXJIVE1MID0gJzxzcGFu
IHN0eWxlPSJ3aWR0aDogJytwZXJjZW50KyclOyI+PC9zcGFuPic7DQoJCX0sDQoJCXVwbG9hZENv
bXBsZXRlIDogZnVuY3Rpb24oYSkgew0KCQkJdGhpcy50b3RhbFVwbG9hZGVkU2l6ZSArPSBhLnRh
cmdldC5nZXQoInNpemUiKTsNCgkJCXZhciBpZCA9IGEudGFyZ2V0LmdldCgiaWQiKSwgcGVyY2Vu
dCA9IE1hdGgubWluKDEwMCwgYS5wZXJjZW50TG9hZGVkKSwNCgkJCQl0b3RhbFBlcmNlbnQgPSB0
aGlzLnRvdGFsVXBsb2FkZWRTaXplICogMTAwMDAgLyB0aGlzLnRvdGFsRmlsZVNpemUgLyAxMDA7
DQoJCQkxMDAgPiB0b3RhbFBlcmNlbnQgJiYgKHRvdGFsUGVyY2VudCA9IHBhcnNlRmxvYXQodG90
YWxQZXJjZW50KS50b0ZpeGVkKDIpKTsNCgkJCWlmICh0aGlzLnRvdGFsRmlsZVNpemUgPT09IDAp
DQoJCQkJcGVyY2VudCA9IDEwMDsNCg0KCQkJaWYgKCF0aGlzLnVwbG9hZEluZm9baWRdKSByZXR1
cm4gZmFsc2U7DQoJCQkNCgkJCXZhciBpbmZvID0gew0KCQkJCWlkOiAgICAgICAgICAgICAgICAg
aWQsDQoJCQkJbmFtZTogICAgICAgICAgICAgICBhLnRhcmdldC5nZXQoIm5hbWUiKSwNCgkJCQls
b2FkZWQ6ICAgICAgICAgICAgIGEudGFyZ2V0LmdldCgic2l6ZSIpLA0KCQkJCWZvcm1hdExvYWRl
ZDogICAgICAgdGhpcy5mb3JtYXRCeXRlcyhhLnRhcmdldC5nZXQoInNpemUiKSksDQoJCQkJc2l6
ZTogICAgICAgICAgICAgICBhLnRhcmdldC5nZXQoInNpemUiKSwNCgkJCQlmb3JtYXRTaXplOiAg
ICAgICAgIHRoaXMuZm9ybWF0Qnl0ZXMoYS50YXJnZXQuZ2V0KCJzaXplIikpLA0KCQkJCXBlcmNl
bnQ6ICAgICAgICAgICAgMTAwLA0KCQkJCXRvdGFsU2l6ZTogICAgICAgICAgdGhpcy50b3RhbEZp
bGVTaXplLA0KCQkJCWZvcm1hdFRvdGFsU2l6ZTogICAgdGhpcy5mb3JtYXRCeXRlcyh0aGlzLnRv
dGFsRmlsZVNpemUpLA0KCQkJCXRvdGFsTG9hZGVkOiAgICAgICAgdGhpcy50b3RhbFVwbG9hZGVk
U2l6ZSwNCgkJCQlmb3JtYXRUb3RhbExvYWRlZDogIHRoaXMuZm9ybWF0Qnl0ZXModGhpcy50b3Rh
bFVwbG9hZGVkU2l6ZSksDQoJCQkJdG90YWxQZXJjZW50OiAgICAgICB0b3RhbFBlcmNlbnQsDQoJ
CQkJbXNnOiAgICAgICAgICAgICAgICBhLmRhdGENCgkJCX07DQoJCQkvKiogdXBsb2FkZWQgZmxh
ZyBhbmQgaXRzIGNhbGxiYWNrIGZ1bmN0aW9uLiAqLw0KCQkJdGhpcy51cGxvYWRJbmZvW2lkXS51
cGxvYWRDb21wbGV0ZSA9ICEwOw0KCQkJDQoJCQlpZiAoIXRoaXMuY29uZmlnLmN1c3RvbWVyZWQp
IHsNCgkJCQl2YXIgcHJvZ3Jlc3NOb2RlID0gdGhpcy51cGxvYWRJbmZvW2lkXS5wcm9ncmVzc05v
ZGUsDQoJCQkJCWNlbGxJbmZvc05vZGUgPSB0aGlzLnVwbG9hZEluZm9baWRdLmNlbGxJbmZvc05v
ZGUsDQoJCQkJCXNpemUgPSBhLnRhcmdldC5nZXQoInNpemUiKSwgYSA9IGV2YWwoIigiICsgYS5k
YXRhICsgIikiKSwgZm10U2l6ZSA9IHRoaXMuZm9ybWF0Qnl0ZXMoc2l6ZSk7DQoJCQkJdGhpcy5n
ZXROb2RlKCJzdHJlYW0tcHJvY2Vzcy1iYXIiLCBwcm9ncmVzc05vZGUpLmlubmVySFRNTCA9ICI8
c3BhbiBzdHlsZT0nd2lkdGg6MTAwJTsnPjwvc3Bhbj4iOw0KCQkJCXRoaXMuZ2V0Tm9kZSgic3Ry
ZWFtLXBlcmNlbnQiLCBwcm9ncmVzc05vZGUpLmlubmVySFRNTCA9ICIxMDAlIjsNCgkJCQl0aGlz
LmdldE5vZGUoInN0cmVhbS11cGxvYWRlZCIsIGNlbGxJbmZvc05vZGUpLmlubmVySFRNTCA9IGZt
dFNpemUgKyAiLyIgKyBmbXRTaXplOw0KCQkJCXRoaXMuZ2V0Tm9kZSgic3RyZWFtLXJlbWFpbi10
aW1lIiwgY2VsbEluZm9zTm9kZSkuaW5uZXJIVE1MID0gIjAwOjAwOjAwIjsNCgkJCQl0aGlzLmdl
dE5vZGUoInN0cmVhbS1jYW5jZWwiLCBwcm9ncmVzc05vZGUpLmlubmVySFRNTCA9ICIiOw0KCQkJ
CQ0KCQkJCXZhciBfbG9hZGVkID0gdGhpcy5mb3JtYXRCeXRlcyh0aGlzLnRvdGFsVXBsb2FkZWRT
aXplKTsNCgkJCQl2YXIgcGVyY2VudCA9IHRoaXMudG90YWxVcGxvYWRlZFNpemUgKiAxMDAwMCAv
IHRoaXMudG90YWxGaWxlU2l6ZSAvIDEwMDsNCgkJCQkxMDAgPiBwZXJjZW50ICYmIChwZXJjZW50
ID0gcGFyc2VGbG9hdChwZXJjZW50KS50b0ZpeGVkKDIpKTsNCgkJCQlpZiAodGhpcy50b3RhbEZp
bGVTaXplID09PSAwKQ0KCQkJCQlwZXJjZW50ID0gMTAwOw0KCQkJCXRoaXMuZ2V0Tm9kZSgiX3N0
cmVhbS10b3RhbC11cGxvYWRlZCIsIHRoaXMudG90YWxDb250YWluZXJQYW5lbCkuaW5uZXJIVE1M
ID0gX2xvYWRlZDsNCgkJCQl0aGlzLmdldE5vZGUoInN0cmVhbS1wZXJjZW50IiwgdGhpcy50b3Rh
bENvbnRhaW5lclBhbmVsKS5pbm5lckhUTUwgPSBwZXJjZW50ICsgIiUiOw0KCQkJCXRoaXMuZ2V0
Tm9kZSgic3RyZWFtLXByb2Nlc3MtYmFyIiwgdGhpcy50b3RhbENvbnRhaW5lclBhbmVsKS5pbm5l
ckhUTUwgPSAnPHNwYW4gc3R5bGU9IndpZHRoOiAnK3BlcmNlbnQrJyU7Ij48L3NwYW4+JzsNCgkJ
CX0NCgkJCQ0KCQkJdGhpcy5jb21wbGV0ZVVwbG9hZChpbmZvKTsNCgkJfSwNCgkJZ2V0Tm9kZSA6
IGZ1bmN0aW9uKGEsIGIpIHsNCgkJCXJldHVybiBmQ29udGFpbnMoYiB8fCB0aGlzLmNvbnRhaW5l
clBhbmVsLCBhKVswXSB8fCBudWxsOw0KCQl9LA0KCQl1cGxvYWRFcnJvciA6IGZ1bmN0aW9uKGV2
dCkgew0KCQkJdGhpcy5nZXQoIm9uVXBsb2FkRXJyb3IiKSA/IHRoaXMuZ2V0KCJvblVwbG9hZEVy
cm9yIikoZXZ0LnN0YXR1cywgZXZ0LnN0YXR1c1RleHQpIDogdGhpcy5vblVwbG9hZEVycm9yKGV2
dC5zdGF0dXMsIGV2dC5zdGF0dXNUZXh0KTsNCgkJfSwNCgkJZmlsZVNlbGVjdCA6IGZ1bmN0aW9u
KGEpIHsNCgkJCXZhciBhID0gYS5maWxlTGlzdCwgYiA9IDAsIGMsIGZpbGVzID0gW107DQoJCQlm
b3IgKGMgPSAwOyBjIDwgYS5sZW5ndGg7IGMrKykNCgkJCQlmaWxlcy5wdXNoKGFbY10uY29uZmln
KTsNCgkJCXRoaXMuZ2V0KCJvblNlbGVjdCIpID8gdGhpcy5nZXQoIm9uU2VsZWN0IikoZmlsZXMp
IDogdGhpcy5vblNlbGVjdChmaWxlcyk7DQoJCQlmb3IgKGMgaW4gdGhpcy51cGxvYWRJbmZvKQ0K
CQkJCWIrKzsNCgkJCWlmIChiID09IHRoaXMuZ2V0KCJzaW1MaW1pdCIpIHx8IGEubGVuZ3RoID4g
dGhpcy5nZXQoInNpbUxpbWl0IikpIHsNCgkJCQl0aGlzLmdldCgib25GaWxlQ291bnRFeGNlZWQi
KSA/IHRoaXMuZ2V0KCJvbkZpbGVDb3VudEV4Y2VlZCIpKE1hdGgubWF4KGEubGVuZ3RoLCBiKSwg
dGhpcy5nZXQoInNpbUxpbWl0IikpDQoJCQkJCQk6IHRoaXMub25GaWxlQ291bnRFeGNlZWQoTWF0
aC5tYXgoYS5sZW5ndGgsIGIpLCB0aGlzLmdldCgic2ltTGltaXQiKSk7DQoJCQkJcmV0dXJuICEx
Ow0KCQkJfQ0KCQkJZm9yIChjID0gMDsgYyA8IGEubGVuZ3RoOyBjKyspDQoJCQkJdGhpcy52YWxp
ZGF0ZUZpbGUoYVtjXSkgJiYgdGhpcy5hZGRTdHJlYW1UYXNrKGFbY10pOw0KCQl9LA0KCQl2YWxp
ZGF0ZUZpbGUgOiBmdW5jdGlvbih1cGxvYWRlcikgew0KCQkJdmFyIG5hbWUgPSB1cGxvYWRlci5n
ZXQoIm5hbWUiKSwgc2l6ZSA9IHVwbG9hZGVyLmdldCgic2l6ZSIpLA0KCQkJCWV4dCA9IC0xICE9
PSBuYW1lLmluZGV4T2YoIi4iKSA/IG5hbWUucmVwbGFjZSgvLipbLl0vLCAiIikudG9Mb3dlckNh
c2UoKSA6ICIiLA0KCQkJCWZpbHRlcnMgPSBhRmlsdGVycywgdmFsaWQgPSAhMSwgbXNnID0gIiIs
DQoJCQkJaW5mbyA9IHsNCgkJCQkJaWQ6ICAgICAgICAgICAgICAgdXBsb2FkZXIuZ2V0KCJpZCIp
LA0KCQkJCQluYW1lOiAgICAgICAgICAgICB1cGxvYWRlci5nZXQoIm5hbWUiKSwNCgkJCQkJc2l6
ZTogICAgICAgICAgICAgdXBsb2FkZXIuZ2V0KCJzaXplIiksDQoJCQkJCWZvcm1hdFNpemU6ICAg
ICAgIHRoaXMuZm9ybWF0Qnl0ZXModXBsb2FkZXIuZ2V0KCJzaXplIikpLA0KCQkJCQlsYXN0TW9k
aWZpZWREYXRlOiB1cGxvYWRlci5nZXQoImxhc3RNb2RpZmllZERhdGUiKSwNCgkJCQkJbGltaXRT
aXplOiAgICAgICAgdGhpcy5nZXQoIm1heFNpemUiKSwNCgkJCQkJZm9ybWF0TGltaXRTaXplOiAg
dGhpcy5mb3JtYXRCeXRlcyh0aGlzLmdldCgibWF4U2l6ZSIpKSwNCgkJCQkJZmlsdGVyczogICAg
ICAgICAgZmlsdGVycw0KCQkJCX07DQoJCQlpZighYlN0cmVhbWluZyAmJiBzaXplID4gMjE0NzQ4
MzY0OCl7dGhpcy51cGxvYWRFcnJvcih7c3RhdHVzOjEwMCwgc3RhdHVzVGV4dDoiRmxhc2jmnIDl
pKflj6rog73kuIrkvKAyR+eahOaWh+S7tiEifSk7cmV0dXJuICExO30NCgkJCWlmICh0aGlzLmdl
dCgibWF4U2l6ZSIpIDwgc2l6ZSkNCgkJCQl0aGlzLmdldCgib25NYXhTaXplRXhjZWVkIikgPyB0
aGlzLmdldCgib25NYXhTaXplRXhjZWVkIikoaW5mbykgOiB0aGlzLm9uTWF4U2l6ZUV4Y2VlZChp
bmZvKTsNCgkJCWVsc2Ugew0KCQkJCWZpbHRlcnMubGVuZ3RoIHx8ICh2YWxpZCA9ICEwKTsNCgkJ
CQlmb3IgKHZhciBpID0gMDsgaSA8IGZpbHRlcnMubGVuZ3RoOyBpKyspDQoJCQkJCWZpbHRlcnNb
aV0udG9Mb3dlckNhc2UoKSA9PSAiLiIgKyBleHQgJiYgKHZhbGlkID0gITApOw0KCQkJCWlmICgh
dmFsaWQpDQoJCQkJCXRoaXMuZ2V0KCJvbkV4dE5hbWVNaXNtYXRjaCIpID8gdGhpcy5nZXQoIm9u
RXh0TmFtZU1pc21hdGNoIikoaW5mbykgOiB0aGlzLm9uRXh0TmFtZU1pc21hdGNoKGluZm8pOw0K
CQkJfQ0KCQkJdmFsaWQgJiYgdGhpcy5jb25maWcuY3VzdG9tZXJlZCAmJiB0aGlzLmdldCgib25B
ZGRUYXNrIikoaW5mbykgJiYgdGhpcy5nZXQoIm9uQWRkVGFzayIpKGluZm8pOw0KCQkJcmV0dXJu
IHZhbGlkOw0KCQl9LA0KCQlmb3JtYXRTcGVlZCA6IGZ1bmN0aW9uKGEpIHsNCgkJCXZhciBiID0g
MDsNCgkJCTEwMjQgPD0gTWF0aC5yb3VuZChhIC8gMTAyNCkgDQoJCQkJPyAoYiA9IE1hdGgucm91
bmQoMTAwICogKGEgLyAxMDQ4NTc2KSkgLyAxMDAsIGIgPSBNYXRoLm1heCgwLCBiKSwgYiA9IGlz
TmFOKGIpID8gMCA6IHBhcnNlRmxvYXQoYikudG9GaXhlZCgyKSwgYSA9IGIgKyAiTUIvcyIpDQoJ
CQkJOiAoYiA9IE1hdGgucm91bmQoMTAwICogKGEgLyAxMDI0KSkJLyAxMDAsIGIgPSBNYXRoLm1h
eCgwLCBiKSwgYiA9IGlzTmFOKGIpID8gMCA6IHBhcnNlRmxvYXQoYikudG9GaXhlZCgyKSwgYSA9
IGIgKyAiS0IvcyIpOw0KCQkJcmV0dXJuIGE7DQoJCX0sDQoJCWZvcm1hdEJ5dGVzIDogZnVuY3Rp
b24oc2l6ZSkgew0KCQkJaWYgKHNpemUgPCAxMDApIHsNCgkJCQlyZXR1cm4gKHNpemUgKyAnQicp
Ow0KCQkJfSBlbHNlIGlmIChzaXplIDwgMTAyNDAwKSB7DQoJCQkJc2l6ZSA9IE1hdGgucm91bmQo
MTAwICogKHNpemUgLyAxMDI0KSkgLyAxMDA7DQoJCQkJc2l6ZSA9IGlzTmFOKHNpemUpID8gMCA6
IHBhcnNlRmxvYXQoc2l6ZSkudG9GaXhlZCgyKTsNCgkJCQlyZXR1cm4gKHNpemUgKyAnSycpOw0K
CQkJfSBlbHNlIGlmIChzaXplIDwgMTA0NzUyNzQyNCkgew0KCQkJCXNpemUgPSBNYXRoLnJvdW5k
KDEwMCAqIChzaXplIC8gMTA0ODU3NikpIC8gMTAwOw0KCQkJCXNpemUgPSBpc05hTihzaXplKSA/
IDAgOiBwYXJzZUZsb2F0KHNpemUpLnRvRml4ZWQoMik7DQoJCQkJcmV0dXJuIChzaXplICsgJ00n
KTsNCgkJCX0NCgkJCQ0KCQkJc2l6ZSA9IE1hdGgucm91bmQoMTAwICogKHNpemUgLyAxMDczNzQx
ODI0KSkgLyAxMDA7DQoJCQlzaXplID0gaXNOYU4oc2l6ZSkgPyAwIDogcGFyc2VGbG9hdChzaXpl
KS50b0ZpeGVkKDIpOw0KCQkJcmV0dXJuIChzaXplICsgJ0cnKTsNCgkJfSwNCgkJZm9ybWF0VGlt
ZSA6IGZ1bmN0aW9uKHRpbWUpIHsNCgkJCXZhciB0b3RhbCA9IHRpbWUgfHwgMCwgaG91ciA9IE1h
dGguZmxvb3IodG90YWwgLyAzNjAwKSwgbWludXRlID0gTWF0aC5mbG9vcigodG90YWwgLSAzNjAw
ICogaG91cikgLyA2MCksDQoJCQkJc2Vjb25kID0gTWF0aC5mbG9vcih0b3RhbCAtIDM2MDAgKiBo
b3VyIC0gNjAgKiBtaW51dGUpLCBob3VyID0gIiIgKyAoIWlzTmFOKGhvdXIpICYmIDAgPCBob3Vy
ID8gKGhvdXIgPCAxMCA/ICgiMCIgKyBob3VyICsgIjoiKSA6IChob3VyICsgIjoiKSk6ICIwMDoi
KSwNCgkJCQlob3VyID0gaG91ciArICghaXNOYU4obWludXRlKSAmJiAwIDwgbWludXRlID8gKG1p
bnV0ZSA8IDEwID8gKCIwIiArIG1pbnV0ZSArICI6IikgOiBtaW51dGUgKyAiOiIpIDogIjAwOiIp
Ow0KCQkJcmV0dXJuIGhvdXIgKz0gIWlzTmFOKHNlY29uZCkgJiYgMCA8IHNlY29uZCA/IChzZWNv
bmQgPCAxMCA/ICgiMCIgKyBzZWNvbmQgKyAiIikgOiBzZWNvbmQpOiAiMDAiOw0KCQl9LA0KCQlw
cmV2ZW50RGVmYXVsdCA6IGZ1bmN0aW9uKGEpIHsNCgkJCWEucHJldmVudERlZmF1bHQgPyBhLnBy
ZXZlbnREZWZhdWx0KCkgOiBhLnJldHVyblZhbHVlID0gITENCgkJfSwNCgkJc3RvcFByb3BhZ2F0
aW9uIDogZnVuY3Rpb24oYSkgew0KCQkJYS5zdG9wUHJvcGFnYXRpb24gPyBhLnN0b3BQcm9wYWdh
dGlvbigpIDogYS5jYW5jZWxCdWJibGUgPSAhMA0KCQl9DQoJfTsNCgkNCgl2YXIgc0lFRmxhc2hD
bGFzc0lkID0gImNsc2lkOmQyN2NkYjZlLWFlNmQtMTFjZi05NmI4LTQ0NDU1MzU0MDAwMCIsDQoJ
CXNTaG9ja3dhdmVGbGFzaCA9ICJhcHBsaWNhdGlvbi94LXNob2Nrd2F2ZS1mbGFzaCIsIHNGbGFz
aFZlcnNpb24gPSAiMTAuMC4yMiIsDQoJCXNGbGFzaERvd25sb2FkID0gImh0dHA6Ly9mcGRvd25s
b2FkLm1hY3JvbWVkaWEuY29tL3B1Yi9mbGFzaHBsYXllci91cGRhdGUvY3VycmVudC9zd2YvYXV0
b1VwZGF0ZXIuc3dmPyIJKyBNYXRoLnJhbmRvbSgpLA0KCQlzRmxhc2hFdmVudEhhbmRsZXIgPSAi
U1dGLmV2ZW50SGFuZGxlciIsDQoJCW9hID0gew0KCQkJYWxpZ24gOiAiIiwNCgkJCWFsbG93RnVs
bFNjcmVlbiA6ICIiLA0KCQkJYWxsb3dOZXR3b3JraW5nIDogIiIsDQoJCQlhbGxvd1NjcmlwdEFj
Y2VzcyA6ICIiLA0KCQkJYmFzZSA6ICIiLA0KCQkJYmdjb2xvciA6ICIiLA0KCQkJbG9vcCA6ICIi
LA0KCQkJbWVudSA6ICIiLA0KCQkJbmFtZSA6ICIiLA0KCQkJcGxheSA6ICIiLA0KCQkJcXVhbGl0
eSA6ICIiLA0KCQkJc2FsaWduIDogIiIsDQoJCQlzY2FsZSA6ICIiLA0KCQkJdGFiaW5kZXggOiAi
IiwNCgkJCXdtb2RlIDogIiINCgkJfTsNCgl2YXIgQnJvd3NlciA9IGZ1bmN0aW9uKGEpIHsNCgkJ
dmFyIGIgPSBmdW5jdGlvbihhKSB7DQoJCQl2YXIgYiA9IDA7DQoJCQlyZXR1cm4gcGFyc2VGbG9h
dChhLnJlcGxhY2UoL1wuL2csIGZ1bmN0aW9uKCkgew0KCQkJCQkJcmV0dXJuIDEgPT0gYisrID8g
IiIgOiAiLiI7DQoJCQkJCX0pKQ0KCQl9LCBjID0gd2luZG93LCBkID0gYyAmJiBjLm5hdmlnYXRv
ciwgZSA9IHsNCgkJCWllIDogMCwNCgkJCW9wZXJhIDogMCwNCgkJCWdlY2tvIDogMCwNCgkJCXdl
YmtpdCA6IDAsDQoJCQlzYWZhcmkgOiAwLA0KCQkJY2hyb21lIDogMCwNCgkJCWZpcmVmb3ggOiAw
LA0KCQkJbW9iaWxlIDogbnVsbCwNCgkJCWFpciA6IDAsDQoJCQlwaGFudG9tanMgOiAwLA0KCQkJ
YWlyIDogMCwNCgkJCWlwYWQgOiAwLA0KCQkJaXBob25lIDogMCwNCgkJCWlwb2QgOiAwLA0KCQkJ
aW9zIDogbnVsbCwNCgkJCWFuZHJvaWQgOiAwLA0KCQkJc2lsayA6IDAsDQoJCQlhY2NlbCA6ICEx
LA0KCQkJd2Vib3MgOiAwLA0KCQkJY2FqYSA6IGQgJiYgZC5jYWphVmVyc2lvbiwNCgkJCXNlY3Vy
ZSA6ICExLA0KCQkJb3MgOiBudWxsLA0KCQkJbm9kZWpzIDogMA0KCQl9LCBhID0gYSB8fCBkICYm
IGQudXNlckFnZW50LCBkID0gKGMgPSBjICYmIGMubG9jYXRpb24pICYmIGMuaHJlZiwgYyA9IDAs
IGYsIGcsIGg7DQoJCWUudXNlckFnZW50ID0gYTsNCgkJZS5zZWN1cmUgPSBkICYmIDAgPT09IGQu
dG9Mb3dlckNhc2UoKS5pbmRleE9mKCJodHRwcyIpOw0KCQlpZiAoYSkgew0KCQkJaWYgKC93aW5k
b3dzfHdpbjMyL2kudGVzdChhKSkNCgkJCQllLm9zID0gIndpbmRvd3MiOw0KCQkJZWxzZSBpZiAo
L21hY2ludG9zaHxtYWNfcG93ZXJwYy9pLnRlc3QoYSkpDQoJCQkJZS5vcyA9ICJtYWNpbnRvc2gi
Ow0KCQkJZWxzZSBpZiAoL2FuZHJvaWQvaS50ZXN0KGEpKQ0KCQkJCWUub3MgPSAiYW5kcm9pZCI7
DQoJCQllbHNlIGlmICgvc3ltYm9zL2kudGVzdChhKSkNCgkJCQllLm9zID0gInN5bWJvcyI7DQoJ
CQllbHNlIGlmICgvbGludXgvaS50ZXN0KGEpKQ0KCQkJCWUub3MgPSAibGludXgiOw0KCQkJZWxz
ZSBpZiAoL3JoaW5vL2kudGVzdChhKSkNCgkJCQllLm9zID0gInJoaW5vIjsNCgkJCWlmICgvS0hU
TUwvLnRlc3QoYSkpDQoJCQkJZS53ZWJraXQgPSAxOw0KCQkJaWYgKC9JRU1vYmlsZXxYQkxXUDcv
LnRlc3QoYSkpDQoJCQkJZS5tb2JpbGUgPSAid2luZG93cyI7DQoJCQlpZiAoL0Zlbm5lYy8udGVz
dChhKSkNCgkJCQllLm1vYmlsZSA9ICJnZWNrbyI7DQoJCQlpZiAoKGQgPSBhLm1hdGNoKC9BcHBs
ZVdlYktpdFwvKFteXHNdKikvKSkgJiYgZFsxXSkgew0KCQkJCWUud2Via2l0ID0gYihkWzFdKTsN
CgkJCQlpZiAoKGQgPSBhLm1hdGNoKC9WZXJzaW9uXC8oW15cc10qKS8pKSAmJiBkWzFdKQ0KCQkJ
CQllLnNhZmFyaSA9IGRbMV07DQoJCQkJaWYgKC9QaGFudG9tSlMvLnRlc3QoYSkgJiYgKGQgPSBh
Lm1hdGNoKC9QaGFudG9tSlNcLyhbXlxzXSopLykpDQoJCQkJCQkmJiBkWzFdKQ0KCQkJCQllLnBo
YW50b21qcyA9IGIoZFsxXSk7DQoJCQkJaWYgKC9Nb2JpbGVcLy8udGVzdChhKSB8fCAvaVBhZHxp
UG9kfGlQaG9uZS8udGVzdChhKSkgew0KCQkJCQlpZiAoZS5tb2JpbGUgPSAiQXBwbGUiLCAoZCA9
IGEubWF0Y2goL09TIChbXlxzXSopLykpDQoJCQkJCQkJJiYgZFsxXSAmJiAoZCA9IGIoZFsxXS5y
ZXBsYWNlKCJfIiwgIi4iKSkpLCBlLmlvcyA9IGQsIGUub3MgPSAiaW9zIiwgZS5pcGFkID0gZS5p
cG9kID0gZS5pcGhvbmUgPSAwLCAoZCA9IGENCgkJCQkJCQkubWF0Y2goL2lQYWR8aVBvZHxpUGhv
bmUvKSkNCgkJCQkJCQkmJiBkWzBdKQ0KCQkJCQkJZVtkWzBdLnRvTG93ZXJDYXNlKCldID0gZS5p
b3M7DQoJCQkJfSBlbHNlIHsNCgkJCQkJaWYgKGQgPSBhLm1hdGNoKC9Ob2tpYU5bXlwvXSp8d2Vi
T1NcL1xkXC5cZC8pKQ0KCQkJCQkJZS5tb2JpbGUgPSBkWzBdOw0KCQkJCQlpZiAoL3dlYk9TLy50
ZXN0KGEpDQoJCQkJCQkJJiYgKGUubW9iaWxlID0gIldlYk9TIiwgKGQgPSBhDQoJCQkJCQkJCQku
bWF0Y2goL3dlYk9TXC8oW15cc10qKTsvKSkNCgkJCQkJCQkJCSYmIGRbMV0pKQ0KCQkJCQkJZS53
ZWJvcyA9IGIoZFsxXSk7DQoJCQkJCWlmICgvIEFuZHJvaWQvLnRlc3QoYSkpIHsNCgkJCQkJCWlm
ICgvTW9iaWxlLy50ZXN0KGEpKQ0KCQkJCQkJCWUubW9iaWxlID0gIkFuZHJvaWQiOw0KCQkJCQkJ
aWYgKChkID0gYS5tYXRjaCgvQW5kcm9pZCAoW15cc10qKTsvKSkgJiYgZFsxXSkNCgkJCQkJCQll
LmFuZHJvaWQgPSBiKGRbMV0pOw0KCQkJCQl9DQoJCQkJCWlmICgvU2lsay8udGVzdChhKSkgew0K
CQkJCQkJaWYgKChkID0gYS5tYXRjaCgvU2lsa1wvKFteXHNdKilcKS8pKSAmJiBkWzFdKQ0KCQkJ
CQkJCWUuc2lsayA9IGIoZFsxXSk7DQoJCQkJCQlpZiAoIWUuYW5kcm9pZCkNCgkJCQkJCQllLmFu
ZHJvaWQgPSAyLjM0LCBlLm9zID0gIkFuZHJvaWQiOw0KCQkJCQkJaWYgKC9BY2NlbGVyYXRlZD10
cnVlLy50ZXN0KGEpKQ0KCQkJCQkJCWUuYWNjZWwgPSAhMDsNCgkJCQkJfQ0KCQkJCX0NCgkJCQlp
ZiAoKGQgPSBhLm1hdGNoKC8oQ2hyb21lfENyTW98Q3JpT1MpXC8oW15cc10qKS8pKSAmJiBkWzFd
DQoJCQkJCQkmJiBkWzJdKSB7DQoJCQkJCWlmIChlLmNocm9tZSA9IGIoZFsyXSksIGUuc2FmYXJp
ID0gMCwgIkNyTW8iID09PSBkWzFdKQ0KCQkJCQkJZS5tb2JpbGUgPSAiY2hyb21lIjsNCgkJCQl9
IGVsc2UgaWYgKGQgPSBhLm1hdGNoKC9BZG9iZUFJUlwvKFteXHNdKikvKSkNCgkJCQkJZS5haXIg
PSBkWzBdOw0KCQkJfQ0KCQkJaWYgKCFlLndlYmtpdCkNCgkJCQlpZiAoL09wZXJhLy50ZXN0KGEp
KSB7DQoJCQkJCWlmICgoZCA9IGEubWF0Y2goL09wZXJhW1xzXC9dKFteXHNdKikvKSkgJiYgZFsx
XSkNCgkJCQkJCWUub3BlcmEgPSBiKGRbMV0pOw0KCQkJCQlpZiAoKGQgPSBhLm1hdGNoKC9WZXJz
aW9uXC8oW15cc10qKS8pKSAmJiBkWzFdKQ0KCQkJCQkJZS5vcGVyYSA9IGIoZFsxXSk7DQoJCQkJ
CWlmICgvT3BlcmEgTW9iaS8udGVzdChhKSAmJiAoZS5tb2JpbGUgPSAib3BlcmEiLCAoZCA9IGEu
cmVwbGFjZSgiT3BlcmEgTW9iaSIsICIiKS5tYXRjaCgvT3BlcmEgKFteXHNdKikvKSkgJiYgZFsx
XSkpDQoJCQkJCQllLm9wZXJhID0gYihkWzFdKTsNCgkJCQkJaWYgKGQgPSBhLm1hdGNoKC9PcGVy
YSBNaW5pW147XSovKSkNCgkJCQkJCWUubW9iaWxlID0gZFswXTsNCgkJCQl9IGVsc2UgaWYgKChk
ID0gYS5tYXRjaCgvTVNJRVxzKFteO10qKS8pKSAmJiBkWzFdKQ0KCQkJCQllLmllID0gYihkWzFd
KTsNCgkJCQllbHNlIGlmIChkID0gYS5tYXRjaCgvR2Vja29cLyhbXlxzXSopLykpIHsNCgkJCQkJ
aWYgKGUuZ2Vja28gPSAxLCAoZCA9IGEubWF0Y2goL3J2OihbXlxzXCldKikvKSkgJiYgZFsxXSkN
CgkJCQkJCWUuZ2Vja28gPSBiKGRbMV0pOw0KCQkJCQlpZiAoKGQgPSBhLm1hdGNoKC8oRmlyZWZv
eClcLyhbXlxzXSopLykpICYmIGRbMV0gJiYgZFsyXSkNCgkJCQkJCWUuZmlyZWZveCA9IGRbMl07
DQoJCQkJfQ0KCQl9DQoJCWlmIChlLmdlY2tvIHx8IGUud2Via2l0IHx8IGUub3BlcmEpIHsNCgkJ
CWlmIChiID0gbmF2aWdhdG9yLm1pbWVUeXBlc1siYXBwbGljYXRpb24veC1zaG9ja3dhdmUtZmxh
c2giXSkNCgkJCQlpZiAoYiA9IGIuZW5hYmxlZFBsdWdpbikNCgkJCQkJZiA9IGIuZGVzY3JpcHRp
b24ucmVwbGFjZSgvXHNbcmRdL2csICIuIikucmVwbGFjZSgNCgkJCQkJCQkvW0EtWmEtelxzXSsv
ZywgIiIpLnNwbGl0KCIuIik7DQoJCX0gZWxzZSBpZiAoZS5pZSkgew0KCQkJdHJ5IHsNCgkJCQln
ID0gbmV3IEFjdGl2ZVhPYmplY3QoIlNob2Nrd2F2ZUZsYXNoLlNob2Nrd2F2ZUZsYXNoLjYiKSwg
Zy5BbGxvd1NjcmlwdEFjY2VzcyA9ICJhbHdheXMiOw0KCQkJfSBjYXRjaCAoaikge251bGwgIT09
IGcgJiYgKGMgPSA2KTt9DQoJCQlpZiAoMCA9PT0gYykNCgkJCQl0cnkgew0KCQkJCQloID0gbmV3
IEFjdGl2ZVhPYmplY3QoIlNob2Nrd2F2ZUZsYXNoLlNob2Nrd2F2ZUZsYXNoIiksDQoJCQkJCWYg
PSBoLkdldFZhcmlhYmxlKCIkdmVyc2lvbiIpLnJlcGxhY2UoL1tBLVphLXpcc10rL2csICIiKS5z
cGxpdCgiLCIpOw0KCQkJCX0gY2F0Y2ggKHMpIHt9DQoJCX0NCgkJaWYgKGZJc0FycmF5KGYpKSB7
DQoJCQlpZiAoZklzTnVtYmVyKHBhcnNlSW50KGZbMF0sIDEwKSkpDQoJCQkJZS5mbGFzaE1ham9y
ID0gZlswXTsNCgkJCWlmIChmSXNOdW1iZXIocGFyc2VJbnQoZlsxXSwgMTApKSkNCgkJCQllLmZs
YXNoTWlub3IgPSBmWzFdOw0KCQkJaWYgKGZJc051bWJlcihwYXJzZUludChmWzJdLCAxMCkpKQ0K
CQkJCWUuZmxhc2hSZXYgPSBmWzJdOw0KCQl9DQoJCXJldHVybiBlOw0KCX0oKTsNCgl2YXIgYkZp
bGVTbGljZSA9ICExOw0KCXZhciBiU3RyZWFtaW5nID0gZnVuY3Rpb24oKSB7DQoJCXZhciBiRmls
ZSA9ICExLCBiSHRtbDUgPSAhMSwgYkZvcm1EYXRhID0gd2luZG93LkZvcm1EYXRhID8gITAgOiAh
MSwgYlN0cmVhbWluZyA9ICExOw0KCQkidW5kZWZpbmVkIiAhPSB0eXBlb2YgRmlsZSAmJiAidW5k
ZWZpbmVkIiAhPSB0eXBlb2YgKG5ldyBYTUxIdHRwUmVxdWVzdCkudXBsb2FkICYmIChiRmlsZSA9
ICEwKTsNCgkJaWYgKGJGaWxlICYmIChiRmlsZVNsaWNlID0gInNsaWNlIiBpbiBGaWxlLnByb3Rv
dHlwZSB8fCAibW96U2xpY2UiIGluIEZpbGUucHJvdG90eXBlIHx8ICJ3ZWJraXRTbGljZSIgaW4g
RmlsZS5wcm90b3R5cGUpKQ0KCQkJYkh0bWw1ID0gITA7DQoJCShmdW5jdGlvbigpIHsNCgkJCWZv
ciAodmFyIGEgPSAwOyBhIDwgYU90aGVyQnJvd3NlcnMubGVuZ3RoOyBhKyspDQoJCQkJLTEgIT09
IG5hdmlnYXRvci51c2VyQWdlbnQuaW5kZXhPZihhT3RoZXJCcm93c2Vyc1thXSkgJiYgKGJIdG1s
NSA9ICExKTsNCgkJfSkoKTsNCgkJLyoqIHNvbWUgYnJvd3NlcnMgaGFzIHByb2JsZW1zLiAqLw0K
CQkoYkZvcm1EYXRhICYmIEJyb3dzZXIub3MgPT09ICJ3aW5kb3dzIiAmJiBCcm93c2VyLnNhZmFy
aSA9PT0gIjUuMS43IikgJiYgKGJGb3JtRGF0YSA9ICExKTsNCgkJcmV0dXJuIGJGaWxlICYmIChi
Rm9ybURhdGEgfHwgYkh0bWw1KTsNCgl9KCksIGJEcmFnZ2FibGUgPSBiU3RyZWFtaW5nICYmICgn
ZHJhZ2dhYmxlJyBpbiBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdzcGFuJykpLCBiRm9sZGVyID0g
YkRyYWdnYWJsZSAmJiAod2luZG93LndlYmtpdFJlcXVlc3RGaWxlU3lzdGVtIHx8IHdpbmRvdy5y
ZXF1ZXN0RmlsZVN5c3RlbSk7DQoJUHJvdmlkZXIgPSBiU3RyZWFtaW5nID8gU3RyZWFtUHJvdmlk
ZXIgOiBTV0ZQcm92aWRlcjsNCgl3aW5kb3cuU3RyZWFtID0gd2luZG93LlVwbG9hZGVyID0gTWFp
bjsgLyoqIHdpbmRvdy5VcGxvYWRlcuaYr1NXRue7hOS7tueahOWFs+mUruWtlyjkv53nlZkpICov
DQp9KSgpOw0K

@@ bootstrap.html.ep 
<!DOCTYPE html>
<html>
<head>
<title>Stream上传插件 - Bootstrap Demo</title>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link href="stream-v1.css" rel="stylesheet" type="text/css">
<link href="http://cdn.bootcss.com/bootstrap/3.1.1/css/bootstrap.min.css" rel="stylesheet">
<!--[if lt IE 9]>
    <script src="http://cdn.bootcss.com/html5shiv/3.7.0/html5shiv.min.js"></script>
    <script src="http://cdn.bootcss.com/respond.js/1.3.0/respond.min.js"></script>
<![endif]-->
<style>.btn-group > button {width: 100px;}</style>
</head>
<body>

<div class="container">
	<div class="row clearfix">
		<div class="col-md-7 column">
			<div class="page-header">
			  <h1>Stream上传插件 <small>bootstrap style demo</small></h1>
			</div>

			<div class="dropzone dz-clickable" id="i_stream_dropzone">
			</div>

			<div class="btn-toolbar" role="toolbar">
				<div class="btn-group">
					<button type="button" class="btn btn-default" id="i_select_files"><span class="glyphicon glyphicon-plus-sign"></span> 添加文件</button>
					<button type="button" class="btn btn-default" onclick="javascript:_t.upload();"><span class="glyphicon glyphicon-upload"></span> 开始上传</button>
					<button type="button" class="btn btn-default" onclick="javascript:_t.stop();"><span class="glyphicon glyphicon-stop"></span> 停止上传</button>
					<button type="button" class="btn btn-default" onclick="javascript:_t.cancel();"><span class="glyphicon glyphicon-remove-sign"></span> 取消上传</button>
				</div>
				<div class="btn-group">
					<button type="button" class="btn btn-default" onclick="javascript:_t.disable();"><span class="glyphicon glyphicon-minus-sign"></span> 禁用选择</button>
					<button type="button" class="btn btn-default" onclick="javascript:_t.enable();"><span class="glyphicon glyphicon-ok-sign"></span> 激活选择</button>
				</div>
			</div>

			<table id="data_table" class="table tablesorter">
				<thead>
					<tr><th>编号</th>
						<th>文件</th>
						<th>大小</th>
						<th>操作</th>
					</tr>
				</thead>
				<tbody id="bootstrap-stream-container">
				</tbody>
				<tfoot id="stream_total_progress_bar">
					<tr><th colspan="2">
							<div class="progress">
							  <div class="progress-bar progress-bar-success" role="progressbar" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100" style="width: 0%">
							  </div>
							</div>
						</th>
						<th colspan="2"><span class="stream_total_size"></span>
							<span class="stream_total_percent"></span>
						</th>
					</tr>
				</tfoot>
			</table>
		</div>
		
		<div class="col-md-5 column">
			<p>Bootstrap是目前十分流行的前端技术，具有功能强大，易上手，样式齐全等等特征。此前<strong>Stream上传插件</strong>是套用网易的上传UI，虽然满足了大多数人的需要，但是在某些情况下，UI风格不符合，导致放弃。所以在<strong>Stream上传插件</strong>的新版本<strong>stream-v1.4.*</strong>就开始支持自定义UI。
			当然，修改了一下响应函数，也新增了一些！<br>
			新增：
				<ol>
				  <li><code>config.customered</code></li>
				  <li><code>config.onAddTask: function(file){}</code></li>
				  <li><pre>var _t = new Stream(config); <br>_t.bStreaming (true: html5方式上传)</pre></li>
				  <li><code>_t.bDraggable (true: 浏览器支持拖拽上传)</code></li>
				</ol>
			</p>
            
			<div id="i_error_tips" class="alert alert-success alert-dismissable">
				<button type="button" class="close" data-dismiss="alert" aria-hidden="true">×</button>
				<strong> 提示： </strong> <span class="text-message"><span> 
			</div>
		</div>
	</div>	
</div>

<script src="http://cdn.bootcss.com/jquery/1.10.2/jquery.min.js"></script>
<script src="http://cdn.bootcss.com/bootstrap/3.1.1/js/bootstrap.min.js"></script>
<script type="text/javascript" src="stream-v1.js"></script>
<script type="text/javascript">
/**
 * 配置文件（如果没有默认字样，说明默认值就是注释下的值）
 * 但是，on*（onSelect， onMaxSizeExceed...）等函数的默认行为
 * 是在ID为i_stream_message_container的页面元素中写日志
 */
 
	var config = {
		enabled: true, /** 是否启用文件选择，默认是true */
		customered: true,
		multipleFiles: true, /** 是否允许同时选择多个文件，默认是false */	
		autoRemoveCompleted: false, /** 是否自动移除已经上传完毕的文件，非自定义UI有效(customered:false)，默认是false */
		autoUploading: true, /** 当选择完文件是否自动上传，默认是true */
		fileFieldName: "FileData", /** 相当于指定<input type="file" name="FileData">，默认是FileData */
		maxSize: 2147483648, /** 当_t.bStreaming = false 时（也就是Flash上传时），2G就是最大的文件上传大小！所以一般需要 */
		simLimit: 10000, /** 允许同时选择文件上传的个数（包含已经上传过的） */
//		extFilters: [".txt", ".gz", ".jpg", ".png", ".jpeg", ".gif", ".avi", ".html", ".htm"], /** 默认是全部允许，即 [] */
		browseFileId : "i_select_files", /** 文件选择的Dom Id，如果不指定，默认是i_select_files */
		browseFileBtn : "<div>请选择文件</div>", /** 选择文件的按钮内容，非自定义UI有效(customered:false) */
		dragAndDropArea: "i_stream_dropzone",
		filesQueueId : "i_stream_files_queue", /** 文件上传进度显示框ID，非自定义UI有效(customered:false) */
		filesQueueHeight : 450, /** 文件上传进度显示框的高，非自定义UI有效(customered:false)，默认450px */
		messagerId : "i_stream_message_container", /** 消息框的Id，当没有自定义onXXX函数，系统会显示onXXX的部分提示信息，如果没有i_stream_message_container则不显示 */
//		frmUploadURL : "http://customers.duapp.com/fd;", /** Flash上传的URI */
//      uploadURL : "http://customers.duapp.com/upload",
		onSelect: function(files) {
			//console && console.log("-------------onSelect-------------------");
			//console && console.log(files);
			//console && console.log("-------------onSelect-------------------End");
		},
		onMaxSizeExceed: function(file) {
			//console && console.log("-------------onMaxSizeExceed-------------------");
			//console && console.log(file);
			$("#i_error_tips > span.text-message").append("文件[name="+file.name+", size="+file.formatSize+"]超过文件大小限制‵"+file.formatLimitSize+"‵，将不会被上传！<br>");
			//console && console.log("-------------onMaxSizeExceed-------------------End");
		},
		onFileCountExceed : function(selected, limit) {
			//console && console.log("-------------onFileCountExceed-------------------");
			//console && console.log(selected + "," + limit);
			$("#i_error_tips > span.text-message").append("同时最多上传<strong>"+limit+"</strong>个文件，但是已选择<strong>"+selected+"</strong>个<br>");
			//console && console.log("-------------onFileCountExceed-------------------End");
		},
		onExtNameMismatch: function(info) {
			//console && console.log("-------------onExtNameMismatch-------------------");
			//console && console.log(info);
			$("#i_error_tips > span.text-message").append("<strong>"+info.name+"</strong>文件类型不匹配[<strong>"+info.filters.toString() + "</strong>]<br>");
			//console && console.log("-------------onExtNameMismatch-------------------End");
		},
		onAddTask: function(file) {
			 var file = '<tr id="' + file.id + '" class="template-upload fade in">' +
		     '<td><span class="preview">'+file.id+'</span></td>' +
		     '<td><p class="name">' + file.name + '</p>' +
		     '    <div><span class="label label-info">进度：</span> <span class="message-text"></span></div>' +
		     '    <div class="progress progress-striped active" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">' +
			'			<div class="progress-bar progress-bar-success" title="" style="width: 0%;"></div>' +
			'		</div>' +
		     '</td>' +
		     '<td><p class="size">' + file.formatSize + '</p>' +
		     '</td>' +
		     '<td><span class="glyphicon glyphicon-remove" onClick="javascript:_t.cancelOne(\'' + file.id + '\')"></span>' +
		     '</td></tr>';
			
			$("#bootstrap-stream-container").append(file);
		},
		onUploadProgress: function(file) {
			//console && console.log("-------------onUploadProgress-------------------");
			//console && console.log(file);
			
			var $bar = $("#"+file.id).find("div.progress-bar");
			$bar.css("width", file.percent + "%");
			var $message = $("#"+file.id).find("span.message-text");
			$message.text("已上传:" + file.formatLoaded + "/" + file.formatSize + "(" + file.percent + "%" + ") 速  度:" + file.formatSpeed);
			
			var $total = $("#stream_total_progress_bar");
			$total.find("div.progress-bar").css("width", file.totalPercent + "%");
			$total.find("span.stream_total_size").html(file.formatTotalLoaded + "/" + file.formatTotalSize);
			$total.find("span.stream_total_percent").html(file.totalPercent + "%");
			
			//console && console.log("-------------onUploadProgress-------------------End");
		},
		onStop: function() {
			//console && console.log("-------------onStop-------------------");
			//console && console.log("系统已停止上传！！！");
			//console && console.log("-------------onStop-------------------End");
		},
		onCancel: function(file) {
			//console && console.log("-------------onCancel-------------------");
			//console && console.log(file);
			
			$("#"+file.id).remove();
			
			var $total = $("#stream_total_progress_bar");
			$total.find("div.progress-bar").css("width", file.totalPercent + "%");
			$total.find("span.stream_total_size").text(file.formatTotalLoaded + "/" + file.formatTotalSize);
			$total.find("span.stream_total_percent").text(file.totalPercent + "%");
			//console && console.log("-------------onCancel-------------------End");
		},
		onCancelAll: function(numbers) {
			//console && console.log("-------------onCancelAll-------------------");
			//console && console.log(numbers + " 个文件已被取消上传！！！");
			$("#i_error_tips > span.text-message").append(numbers + " 个文件已被取消上传！！！");
			
			//console && console.log("-------------onCancelAll-------------------End");
		},
		onComplete: function(file) {
			//console && console.log("-------------onComplete-------------------");
			//console && console.log(file);
			
			/** 100% percent */
			var $bar = $("#"+file.id).find("div.progress-bar");
			$bar.css("width", file.percent + "%");
			var $message = $("#"+file.id).find("span.message-text");
			$message.text("已上传:" + file.formatLoaded + "/" + file.formatSize + "(" + file.percent + "%" + ")");
			/** remove the `cancel` button */
			var $cancelBtn = $("#"+file.id).find("td:last > span");
			$cancelBtn.remove();
			
			/** modify the total progress bar */
			var $total = $("#stream_total_progress_bar");
			$total.find("div.progress-bar").css("width", file.totalPercent + "%");
			$total.find("span.stream_total_size").text(file.formatTotalLoaded + "/" + file.formatTotalSize);
			$total.find("span.stream_total_percent").text(file.totalPercent + "%");
			
			//console && console.log("-------------onComplete-------------------End");
		},
		onQueueComplete: function(msg) {
			//console && console.log("-------------onQueueComplete-------------------");
			//console && console.log(msg);
			//console && console.log("-------------onQueueComplete-------------------End");
		},
		onUploadError: function(status, msg) {
			//console && console.log("-------------onUploadError-------------------");
			//console && console.log(msg + ", 状态码:" + status);
			
			$("#i_error_tips > span.text-message").append(msg + ", 状态码:" + status);
			
			//console && console.log("-------------onUploadError-------------------End");
		}
	};
	var _t = new Stream(config);
	/** 不支持拖拽，隐藏拖拽框 */
	if (!_t.bDraggable) {
		$("#i_stream_dropzone").hide();
	}
	/** Flash最大支持2G */
	if (!_t.bStreaming) {
		_t.config.maxSize = 2147483648;
	}
</script>
</body>

@@ upload.gif (base64)
R0lGODlhEAAQANU6AF+LXX5+fuD13+f65vX19fv7+93229r02MnJyWeQZYuLi/Hx8c/Pz3HjaTTL
KiK8GWNjY0nCQ4mJidra2mFhYYCAgFtbW42NjaKiovn5+aCgoM3NzeTk5Hx8fPf393Z2duX44+L2
4eDg4HR0dP39/YSEhLa2tq6urmpqar29vcHBweLi4tzc3GVlZe7u7pubm9PT08PDw9HR0ezs7Kqq
qo+Pj5eXl4eHh7+/v5WVlf///wAAAAAAAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh/wtY
TVAgRGF0YVhNUDw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3pr
YzlkIj8+Cjx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2Jl
IFhNUCBDb3JlIDQuMi4yLWMwNjMgNTMuMzUyNjI0LCAyMDA4LzA3LzMwLTE4OjA1OjQxICAgICAg
ICAiPgogPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJk
Zi1zeW50YXgtbnMjIj4KICA8cmRmOkRlc2NyaXB0aW9uIHJkZjphYm91dD0iIgogICAgeG1sbnM6
eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIgogICAgeG1sbnM6ZGM9Imh0dHA6Ly9w
dXJsLm9yZy9kYy9lbGVtZW50cy8xLjEvIgogICAgeG1sbnM6cGhvdG9zaG9wPSJodHRwOi8vbnMu
YWRvYmUuY29tL3Bob3Rvc2hvcC8xLjAvIgogICB4bXA6Q3JlYXRvclRvb2w9IkFkb2JlIFBob3Rv
c2hvcCBDUzQgTWFjaW50b3NoIgogICB4bXA6Q3JlYXRlRGF0ZT0iMjAwOS0xMi0zMFQxNjoyMzo0
NSswODowMCIKICAgeG1wOk1vZGlmeURhdGU9IjIwMDktMTItMzBUMTY6MjM6NDUrMDg6MDAiCiAg
IHhtcDpNZXRhZGF0YURhdGU9IjIwMDktMTItMzBUMTY6MjM6NDUrMDg6MDAiCiAgIGRjOmZvcm1h
dD0iYXBwbGljYXRpb24vdm5kLmFkb2JlLnBob3Rvc2hvcCIKICAgcGhvdG9zaG9wOkNvbG9yTW9k
ZT0iMyIKICAgcGhvdG9zaG9wOklDQ1Byb2ZpbGU9InNSR0IgSUVDNjE5NjYtMi4xIi8+CiA8L3Jk
ZjpSREY+CjwveDp4bXBtZXRhPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAog
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAg
ICAgICAgICAgICAgICAgCjw/eHBhY2tldCBlbmQ9InciPz4B//79/Pv6+fj39vX08/Lx8O/u7ezr
6uno5+bl5OPi4eDf3t3c29rZ2NfW1dTT0tHQz87NzMvKycjHxsXEw8LBwL++vby7urm4t7a1tLOy
sbCvrq2sq6qpqKempaSjoqGgn56dnJuamZiXlpWUk5KRkI+OjYyLiomIh4aFhIOCgYB/fn18e3p5
eHd2dXRzcnFwb25tbGtqaWhnZmVkY2JhYF9eXVxbWllYV1ZVVFNSUVBPTk1MS0pJSEdGRURDQkFA
Pz49PDs6OTg3NjU0MzIxMC8uLSwrKikoJyYlJCMiISAfHh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgH
BgUEAwIBAAAh+QQFHgA6ACwAAAAAEAAQAAAGkkCdcJjRWCy2zHApLEg6nFmAxhw6AwSCbhOo6gqK
wEKi0Z1uVbBYUfEgWhNm4bJuIyAyJqkmvlQIdwwiHEspHwQYHYAUDBMQG0slKjooMDGMjjhMHww6
LwCgoaKgORhCAA2pDQOsrQkrFCY6AA61Dga4uCAJOiwjFgAPwg8HxcUhvEIuABHNEQLQ0cmno9Ve
1zpBACH5BAUeADoALAUACgAHAAQAAAYVwIFQ1yiCDAadYxk6HHSPqGCqi1iDACH5BAUeADoALAgA
CgAHAAQAAAYUwIFQ1ygajjqH8sDUPZ6CqC5CDQIAOw==

@@ bgx.png (base64)
iVBORw0KGgoAAAANSUhEUgAAAAYAAAH0CAMAAAApP6zcAAAAA3NCSVQICAjb4U/gAAAB+FBMVEX6
+vr39/f19fXz8/Po+OXp+Obn9+Ty8vLo9+Xm9uPl9uLl9eLw8PDv7+/k9eHj9ODu7u7i9N/i89/h
897o6Ojn5+fm5ubl5eXk5OTO7c7V67/j4+PV68DN7M3U6r3i4uLU677M68zL68vh4eHT6rzS6rvR
6bjQ6bfK6crK6svg4ODR6brf39/J6cnI6MjO6LTP6LXe3t7d3d3H58fM57HN57LF5sXF5sTL5q/G
5sbK5q3J5qzH5anI5arD5MPG5KfB48LF5KbA4sG/4sDD46PC46HE46S+4b+94L7B4qDA4p7A4p+/
4Z273ry83r2/4Zy63ru53bq43Lm227e327i12raz2bW02bay2LSz2LSy17P6ylH4x0v0wUTxuzru
uC2KzIaJy4WIy4SHyoOGyYKDyH+EyICBx31/xXvrrR19xHl7w3dZ0E95wnV3wXN1wHFUzUpzvm/n
pg5uvYNxvW1vvGttu2lrumdOx0VquWVouGP8iW1mtmJktWBGwTxjtV5htF1gs1v4hGZesllfslo+
uzT0fGBArlQ2tSo/rVM9rFI8q1E7qlHwclU6qFAuryM5p084pU02pEs0okoyoUnrakkxnkgvnEUs
m0QrmUMplkEnlUAmkz8jkj3mWDkijzwgjjofjDkeizkcijgbiTcahzbgSyn////+j8zDAAAAqHRS
TlP/////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////wCZ
X+z0AAAACXBIWXMAAAsSAAALEgHS3X78AAAAFnRFWHRDcmVhdGlvbiBUaW1lADAxLzI3LzEwRqa2
TAAAABx0RVh0U29mdHdhcmUAQWRvYmUgRmlyZXdvcmtzIENTNAay06AAAAGeSURBVEiJ7dRVb1RR
GEbhhVuR4sUKFChOcafFKcWKu3txdy3u0KLF7W+SrOS7YIeQyZBpQjLPzbo7ybv3yeanyEV+10SZ
pKn+nGailZIUKNJekU5K8o/77oh74r54IB6Kx+KpeCaeixeiTrwUr8Rr8Ua8Fe9Eg3gvPopP4rP4
Ir6Kb+K7Ijm89/8lJ0WRIn0VGSAGimFiqBglRovxYqqYJCaLWaJCzFFkrlgoFollYqlYIarFSrFa
rBJrxDqxVmwQ68VGxei/ncshcUycE1fELXFXPFEmZ71JbBZbxFaxTRwQJ5TJNy+KG+K2eCTqxQfx
Q1n/KH1EL9Ff9BODxGAxQgwRpaJMjBETxQQxRUwT08VMMUOUi9ligZgn5otKUSUWiyViubLe3lVJ
uilJd0V6KNJTkd6KFCtJiSLDFRmpyFglGadIttu3ix1ip9gldou9Yo/YJ/aLg6JGHBZHxFFxXJwS
p8UZcVacFxfEJXFZXBXXxHVRK26q8V7TFkrSXLQWLZWkjSJtRTvRQZGOSlIoOosuijTa9nzyySef
3OYXSb7F2IM77ekAAAAASUVORK5CYII=

@@ FlashUploader.swf (base64)
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
