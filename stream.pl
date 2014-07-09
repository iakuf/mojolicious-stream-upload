use Mojolicious::Lite;
use Digest::MD5 qw(md5_hex);
use Scalar::Util 'weaken';
use File::Basename (); 
use File::Slurp;
use File::Spec::Functions;
use File::Copy;
use IO::File;
use Encode qw(encode_utf8);
use Cwd;
use utf8;
    
$ENV{MOJO_MAX_MESSAGE_SIZE} = 1073741824;

my $CrossOrigins = 'http://test.yinyuetai.com';
my $FILE_REPOSITORY = "/data/fileupload/t";

app->config(hypnotoad => {listen => ['http://*:3008']});

hook after_build_tx => sub {
    my $tx = shift;
    my $app = shift;
    weaken $tx;

    $tx->req->content->on(body => sub { 
        my $single  = shift;
        my $app     = shift;

        return unless $tx->req->method eq 'POST' or $tx->req->method eq 'OPTIONS';
        return unless $tx->req->url->path->contains('/upload');

        $tx->req->max_message_size(0); # 让基可以上传无限大小

        my $token = $tx->req->param('token');
        my $name  = $tx->req->param('name');
        my $size  = $tx->req->param('size');

        my $path  = catfile($FILE_REPOSITORY, $name);

        my ($from, $to, $range_size);
        if ( $tx->req->headers->content_range  and $tx->req->headers->content_range  =~ m/bytes (\d+)-(\d+)\/(\d+)/) {
            ($from, $to, $range_size) = ($1, $2, $3);
            my $message;
            if (-s $path != $from) {
                $message = 'Error: Range 范围错误';
                $tx->res->code(406);
                $tx->res->finish;
            }
        }

        # 不存在就创建
        createToken($path) unless -f $path;

        my $fh = new IO::File $path, O_WRONLY|O_APPEND;

        $single->unsubscribe('read')->on(read => sub {
          my ($single, $bytes) = @_;
            $fh->sysseek(0, SEEK_END);
            my $len = $fh->syswrite($bytes, length $bytes);
        });

    });
};

get '/' => "index";

get '/tk' => sub { 
    my $self  = shift;
    my $name  = $self->param('name');
    my $size  = $self->param('size');
    my $token = generateInfo({ name => $name, size => $size, token => 1 }); 
    my $path  = catfile($FILE_REPOSITORY, $name); 

    my $success = 1;
    my $message = '';
    createToken($path);

    return $self->render(json => {
        token   => $token,
        server  => $CrossOrigins, 
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
    my $name  = $self->param('name');
    my $size  = $self->param('size');
    my $token = $self->param('token');
    my $path  = catfile($FILE_REPOSITORY, $name);# : generateInfo({ name => $name, size => $size });


    $self->res->headers->header('Access-Control-Allow-Headers' => 'Content-Range,Content-Type');
    $self->res->headers->header('Access-Control-Allow-Origin'  => $CrossOrigins);
    $self->res->headers->header('Access-Control-Allow-Methods' => 'POST, GET, OPTIONS');
    
    # GET 取大小
    return $self->render(json => {
        start   => -s $path || 0,
        success => 1,
        message => '',
    }) if $self->req->method eq 'GET' ;

    return $self->render(json => {
        start   => -s $path,
        success => -s $path ? 1 : 0,
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
    my $token  = $self->req->param('token');
    my $name   = $upload->filename;
    my $size   = $upload->size;

    my $dst = catfile($FILE_REPOSITORY, $name);
    my $dir  = File::Basename::dirname( $dst );
    if (! -e $dir ) {
        if (! File::Path::make_path( $dir ) || ! -d $dir ) {            
             my $e = $!;
             debugf("Failed to createdir %s: %s", $dir, $e);
        }
    }
    $upload->move_to($dst);
    my $len = -s $dst;

    return $self->render(json => {
        start   => $len ? $len : 0, 
        success => $len ? 1 : 0,
        message => '',
    });
};


# 生成 Path， name的Hash值| +_+size的值
sub generateInfo {
    my $args = shift;
    return if !$args->{name} or !$args->{size};
    if ( $args->{token} ) {
        return md5_hex(encode_utf8($args->{name})) . "_" . $args->{size}; 
    }
    my $path =  catfile( $FILE_REPOSITORY, md5_hex(encode_utf8($args->{name})) . "_" . $args->{size} );
    return $path;
}

sub createToken {
    my $path = shift;
    return if !$path;

    my $dir  = File::Basename::dirname( $path );
    if (! -e $dir ) {
        if (! File::Path::make_path( $dir ) || ! -d $dir ) {            
             my $e = $!;
             debugf("Failed to createdir %s: %s", $dir, $e);
        }
    }

    if (! -f $path) {
        write_file( $path, '' ) ;
        return 1;
    }
}
app->start();

__DATA__

@@ crossdomain.xml
<?xml version="1.0" encoding="UTF-8"?>
<cross-domain-policy>
<allow-access-from domain="*"/>
</cross-domain-policy>
