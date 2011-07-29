#!/usr/bin/perl

use File::Basename;
use English;
use Cwd;

my ($file, $path) = fileparse(Cwd::abs_path($PROGRAM_NAME));
push @INC, $path;

require RepoHelper || die "Install Error. Unable to find RepoHelper.pm\n";
print "$EXECUTABLE_NAME $PROGRAM_NAME ", Cwd::abs_path($PROGRAM_NAME), "\n";
import RepoHelper;

my $Rev = "Orig";
my $DstDir = "$ENV{HOME}/Work/Bugs/Merge";

if ($#ARGV >= 0) {
  $Rev = shift @ARGV;
}
if ($#ARGV >= 0) {
  $DstDir = shift @ARGV;
}

if (-d "scons-out") {
  my @SaveDirs = grep { chomp }
    Piped("find scons-out/ -type d -name tests", "");
  push @SaveDirs, qw(toolchain/hg-build-newlib
                     toolchain/hg-log
                     toolchain/pnacl_linux_x86_64_newlib);

  &SaveTestArtifacts($Rev, $DstDir,
                     @SaveDirs);
} else {
  die "There is no scons-out direcory. Run $PROGRAM_NAME from a native_client\n";
}
