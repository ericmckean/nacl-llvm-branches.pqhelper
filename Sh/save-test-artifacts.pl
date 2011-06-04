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
my $DstDir = "~/Work/Bugs/Merge";

if ($#ARGV >= 0) {
  $Rev = shift @ARGV;
}
if ($#ARGV >= 0) {
  $DstDir = shift @ARGV;
}

if (-d "scons-out") {
  &SaveTestArtifacts($Rev, $DstDir,
                     grep { chomp }
                     Piped("find scons-out/ -type d -name tests", ""));
} else {
  die "There is no scons-out direcory. Run $PROGRAM_NAME from a native_client\n";
}
