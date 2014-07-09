# Stream 的 Perl 后端 
本后端是使用 Perl 中常用的框架 Mojolicious 实现. 本程序做为后端接收上传过来的大文件的时候, 完全使用的是异步流式处理, 所以就算是单进程, 也可以处理多个上传的请求. 并且不会有多少内存的占用.
因为使用 Mojolicious 实现, 所以需要安装这个框架和一些相关的模块. Perl 中模块的安装需要使用 cpanm 所以先要下载 cpanm .

$ wget  http://xrl.us/cpanm  --no-check-certificate -O /sbin/cpanm
$ chmod +x  /sbin/cpanm 

然后开始安装
cpanm Mojolicious EV Digest::MD5 

安装, 直接使用 stream.pl 来启动就好了
# 静态文件
stream 的实现文件都在项目 http://git.oschina.net/jiangdx/stream 中. 大家需要先克隆这个项目.
    I. 并在 stream.pl 的目标中, 创建 templates public 二个目录
        mkdir templates
        mkdir public
    II. 并需要复制 stream 的 git 项目中的静态文件到相应的这二个目录
        cp -r stream/{css,js}  ./public
        cp index.html ./templates/index.html.ep

# 配置
哪些域名的文件, 是可以接收并存储的
my $CrossOrigins = 'http://test.yinyuetai.com';

文件存储的目录
my $FILE_REPOSITORY = "/data/fileupload/t";

修改服务器启动的端口
app->config(hypnotoad => {listen => ['http://*:3008']});


# Perl 版本 Stream 启动
hyphotoad 是一个常用的 Perl 后端的 Web 异步服务器, 为 Mojolicious 的原生配置. 多进程, 为 Unix 优化过. 所以使用它来启动, 
hypnotoad stream.pl 

现在就可以直接打开这个服务器来进行测试了
