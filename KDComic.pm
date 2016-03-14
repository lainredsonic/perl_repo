package KDComic;

use version;

our $VERSION = 0.1;

use utf8;
use Moose;
use Encode;
use File::Find::Rule;
use File::Basename;
use File::Spec;

extends 'EBook::EPUB';

has '+tmpdir' => (
	isa	=> 'Str',
	is	=> 'ro',
	default => '/tmp'
);

has 'src_path' => (
	isa	=> 'Str',
	is	=> 'rw',
);

has 'title' => (
	isa	=> 'Str',
	is	=> 'rw',
);

has 'genexec' => (
    isa => 'Str',
    is  => 'ro',
    default => '/mnt/nas-1/kindle/kindlegen_linux_2.6_i386_v2_9/kindlegen',
);

my %vol;

sub cleanup
{
    my ($tmpdir) = @_;
    print "cleanup\n";
    unlink glob("$tmpdir/*.html");
    unlink glob("$tmpdir/*.opf");
    unlink glob("$tmpdir/*.ncx");
    unlink glob("$tmpdir/*.mobi");
    rmdir $tmpdir;
}

sub DEMOLISH
{
    my ($self) = @_;
    my $tmpdir = $self->tmpdir.'/OPS';
    my $title = $self->title;
    my $src_path = $self->src_path;
    if (defined $title and $title ne ""){
        File::Copy::copy(glob("$tmpdir/$title.mobi"), $src_path);
    }
    cleanup $tmpdir;
}

sub gen_xhtml
{
	my ($file_path, $self) = @_;
	my $xhtml;
	my $tmpdir = $self->tmpdir."/OPS";
	my ($res_filnam, $res_dirnam) = fileparse($file_path, qr/\.[^.]*/);
	$res_dirnam =~ s#^.*/(.*)/$#$1#;
	my $xhtmlname="$res_dirnam".'_'."$res_filnam";
	my $filename = "$tmpdir/$xhtmlname".".html";
#	print "$filename ### $xhtmlname ### $file_path\n";

	$xhtml="<!DOCTYPE html SYSTEM \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\"><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>$xhtmlname</title><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/></head><body><div><img src=$file_path /></div></body></html>";

	$self->add_xhtml("$xhtmlname".".html", $xhtml);
}

sub gen_chapter
{
	my ($self, %vol) = @_;
	my $chapter_id=1;
	my @pages;
	my $file_path;
	my $head_page;
	foreach my $chapter (sort keys %vol){
		@pages = sort @{$vol{$chapter}};
		$file_path = $pages[0]; 
		my ($res_filnam, $res_dirnam) = fileparse($file_path, qr/\.[^.]*/);
		$res_filnam =~ s#^(.*)\..*$#$1#;
		$res_dirnam =~ s#^.*/(.*)/$#$1#;
		$head_page = $res_dirnam.'_'.$res_filnam.'.html';
#		print "head: $head_page\n";
		$self->add_navpoint(
			label		=> Encode::decode('UTF-8',$res_dirnam, Encode::FB_CROAK),
			id		=> "$chapter_id",
			content		=> Encode::decode('UTF-8',$head_page, Encode::FB_CROAK),
			play_order	=> $chapter_id,
		);
		$chapter_id ++;
	}
}

sub gen_page
{
	my ($self, %vol) = @_;
	foreach my $chapter (sort keys %vol){
#		print $chapter."\n";
		foreach (sort @{$vol{$chapter}}){
			my $fullpath = Encode::decode('UTF-8', $_, Encode::FB_CROAK);
			gen_xhtml($fullpath, $self);
			$self->add_image_entry($fullpath);
		}
	}
}

sub scandir
{
	my ($src) = @_;
	my %vol;
	my $dirnam;
	my $filnam;
	my $rule = File::Find::Rule->new;
	$rule->file;
	$rule->name(('*.jpg','*.png','*.JPG','*.PNG'));
	my $dir_id=0;
	foreach($rule->in($src)){
		if($_ !~ /^$src$/){
			print $_."\n";
			($filnam, $dirnam) = fileparse($_, qr/\.[^.]*/);
			unless (defined $vol{$dirnam}){
				$vol{$dirnam} = eval("\\@"."content_".$dir_id);
				$dir_id ++;
			}
			push(@{$vol{$dirnam}}, $_);
		}
	}
	return %vol;
}

sub scan
{
	my ($self) = @_;
    $SIG{INT} = \&cleanup;
    my $src_path = $self->src_path;
    if ($src_path eq ""){
        die "No directory specific";
    }
    eval{
        $_ = File::Spec->rel2abs($src_path);
    };
    if ($@){
        die "File path error:$@";
    }
#	s#^(.*)/#$1#;
	$self->src_path($_);
	%vol = scandir($self->src_path);
	gen_chapter($self, %vol);
	gen_page($self, %vol);
}

sub write
{
    my ($self) = @_; 
	my $tmpdir = $self->tmpdir."/OPS";
    my $title;
    $_ = $self->src_path;
	s#^.*/(.*)#$1#;
    $title = Encode::decode('UTF-8',$_, Encode::FB_CROAK);
    $self->title($title);
	$self->add_title($title);
	$self->add_language('en-US');

	$self->add_meta_item('book-type', 'comic');
	$self->add_meta_item('zero-gutter', 'true');
	$self->add_meta_item('zero-margin', 'true');
	$self->add_meta_item('fixed-layout', 'true');
	$self->add_meta_item('orientation-lock', 'portrait');
	$self->add_meta_item('original-resolution', '758x1024');
	
	$self->write_ncx("$tmpdir/toc.ncx");
	$self->write_opf("$tmpdir/content.opf");
}

sub pack
{
    my ($self) = @_;
    my $title = $self->title;
    my $tmpdir = $self->tmpdir."/OPS";
    system $self->genexec, "-verbose", "-dont_append_source",
    "$tmpdir"."/content.opf", "-o", "$title".".mobi";
}

1;
