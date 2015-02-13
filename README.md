# Stream 上传插件介绍

Stream 这个项目主要是为了解决大文件上传, 本程序只是它的一个 Perl 后端的实现. 项目网站是: http://www.twinkling.cn 原始地址是: http://git.oschina.net/jiangdx/stream/wikis/home.
因为它对 HTML5 和 Flash 都支持, 所以很合适做全功能的上传平台. 在这, 感谢作者为我们大家提供这么好的开源项目.

    支持HTML5、Flash两种方式（跨域）上传
    支持多文件一起上传
    HTML5方式支持断点续传，拖拽等新特性
    兼容性好IE7+, FF3.6+, Chrome*，Safari4+，遨游等主流浏览器
    选择文件的按钮完全可以自定义
    进度条、速度、剩余时间等附属信息
    基本的自定义属性及函数，如文件多选、上传成功的响应函数等
    示例代码java实现（StreamServlet, FormDataServlet{commons-fileupload的stream api}, TokenServlet）
    
    注：Chrome没测试最低版本，不想支持IE6

# Stream 的 Perl 后端 

本上传的后端, 是用来接收 HTML5 上传过来的文件, 并存储在指定的位置, 这是使用 Perl 中常用的框架 Mojolicious 实现. 本程序做为后端接收上传过来的大文件的时候, 完全使用的是异步流式处理, 所以就算是单进程, 也可以处理多个上传的请求. 并且不会有多少内存的占用.
因为使用 Mojolicious 实现, 所以需要安装这个框架和一些相关的模块. Perl 中模块的安装需要使用 cpanm 所以先要下载 cpanm .

    $ wget  http://xrl.us/cpanm  --no-check-certificate -O /sbin/cpanm
    $ chmod +x  /sbin/cpanm 

然后开始安装

    $ cpanm EV Digest::MD5 Digest::SHA IO::Compress::Gzip Compress::Raw::Zlib Time::HiRes Asset::File Mojolicious


# 安装

这个 Perl 的后端的 stream 的实现文件都在项目 https://github.com/iakuf/mojolicious-stream-upload 中. 大家需要使用到其中二个文件 stream.pl 和 StreamUpload.conf
所以可以使用任何方法下载这个项目中的文件. 其中 stream.pl 是执行文件, StreamUpload.conf 是配置文件.

stream.pl 可以放在你想给这个执行存放的路径都行, StreamUpload.conf 请放到 '/etc' 的目录下, 这样才能被读取到.

    $ cp StreamUpload.conf /etc/

对于 Stream 中的 js css flash 文件, 我们使用 Mojolicious 的特有功能, 都存储在 stream.pl 本身, 所以你并不需要在单独下载. 如果你想分离这些到相应的目录. 你可以执行以下的命令

    $ perl ./stream.pl inflate

以上命令会从 stream.pl 的 _DATA_ 部分给相应的静态文件都写到 templates 和 public 的目录中.

# 启动

hyphotoad 是一个常用的 Perl 后端的 Web 异步服务器, 为 Mojolicious 的原生配置. 多进程, 为 Unix 优化过. 所以使用它来启动, 

    $ hypnotoad stream.pl 

现在就可以直接打开这个服务器来进行测试了

# 配置

配置中, UploadServer 是一定需要修改的. 监听的端口可以根据实际来配置是否需要修改. FileRepository 一定需要修改. 注意 CrossOrigins 是区分端口的, 如果来源指定的端口错误, 也会认为不是同一个域.

整个配置文件如下:

    {
        hypnotoad => {
            listen => ['http://*:3008'],
                user   => 'newupload',
                group  => 'newupload',
        },
        UploadServer   => 'http://xxx.xxxx.com',
        CrossOrigins   => 'http://xxx.xxxx.com',
        FileRepository => '/tmp/',
        debug          => 1,
        log            => '/var/log/upload.log',
    }

指定用户和组

    user   => 'newupload'
    group  => 'newupload'

可以接收哪些域名的文件, 是可以接收并存储的, 如果本地测试, 接收和取 token 的服务器是同一台, 注意这时这个参数要和 UploadServer 的地址是一样的. 

    CrossOrigins   => 'http://xxx.xxx.com'

文件存储的目录

    FileRepository => '/tmp/'

修改服务器启动的端口

    listen => ['http://*:3008']

