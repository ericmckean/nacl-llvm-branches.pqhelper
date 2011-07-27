#!/usr/bin/perl
# -*- perl -*-


use File::Basename;
use English;
use Cwd;

my ($file, $path) = fileparse(Cwd::abs_path($PROGRAM_NAME));
push @INC, $path;

require RepoHelper || die "Install Error. Unable to find RepoHelper.pm\n";
print "$EXECUTABLE_NAME $PROGRAM_NAME ", Cwd::abs_path($PROGRAM_NAME), "\n";
import RepoHelper;

my @dirs = grep { chomp } Piped("find scons-out/ -type d -name tests", "Find artifact dirs");


foreach (@dirs) {
  Shell("rm -rf $_", "clean");
}
my $NaCl = `pwd`; chomp $NaCl;
my ($LLVMRepo, $LLVMGccRepo);


$ENV{PQ_REV_NAME_MOD} = Piped("git log | grep git-svn | head -1 | cut -d@ -f2 | sed -e 'print \$1'")   
  if (! exists $ENV{PQ_REV_NAME_MOD});
&SetRevNameMod($ENV{PQ_REV_NAME_MOD});
print "PQ_REV_NAME_MOD is $ENV{PQ_REV_NAME_MOD}\n";

chdir "hg/llvm/llvm-trunk";
chomp($LLVMRepo = `pwd`);
Shell("hg qpop -a", "find base SVN rev");
my (%LLVMLog) = &GetHgLog('');
Shell("hg qpush -a", "Push current set of patchs");
my($LLVMRev) = &GetRevName(%LLVMLog);
chdir ".hg/patches";
my(%LLVMMQRevLog) = &GetHgLog('');

chdir $NaCl;
chdir "hg/llvm-gcc/llvm-gcc-4.2";
chomp($LLVMGccRepo = `pwd`);
Shell("hg qpop -a", "find base SVN rev for llvm-gcc");
my (%LLVMGccLog) = &GetHgLog('');
Shell("hg qpush -a", "Push current set of patches");
my($LLVMGccRev) = &GetRevName(%LLVMGccLog);
chdir ".hg/patches";
my(%LLVMGccMQRevLog) = &GetHgLog('');

my (%TestArray) = 
  map { $_ => 1 } qw(x8664 x8664pic x8632 x8632pic arm armpic);
print join(" ", keys %TestArray), "\n";
my $RUN_ALL_TESTS = keys %TestArray;


chdir $NaCl;
my $CurrRevTxt= "$ENV{PQ_REV_NAME_MOD}-$LLVMRev-$LLVMGccRev";

print "*********************************\n";
print "This test is for REVISION $CurrRevTxt\n";
my (@StartTime) = time;
my (@CompileTime, @TestRunTime, @SpecTime);
my $ResetMQ     = 0;
my $Clean       = 0;
my $Download    = 1;
my $Compile     = 1;
my $DoTest      = 1; 
my $DoSpec      = 1;
my $TagSuccess = 0;

$ResetMQ = 1 if (grep { /^-ResetMQ$/i } @ARGV);
$Clean = 1 if  (grep { /^-Clean$/i } @ARGV);
$Compile = 0 if (grep { /^-SkipCompile$/i  } @ARGV);
$DoTest = 0 if (grep { /^-SkipTest$/i } @ARGV);
$DoSpec = 0 if (grep { /^-SkipSpec$/i } @ARGV);
$Download = 0 if (grep { /^-SkipDownload$/i } @ARGV);
my (@SkippedTests);

push @SkippedTests, grep { /^x86/ } keys %TestArray if (grep { /^-SkipX86$/i } @ARGV);
push @SkippedTests, grep { /^x8664/ } keys %TestArray if (grep { /^-SkipX8664$/i } @ARGV);
push @SkippedTests, grep { /^x8632/ } keys %TestArray if (grep { /^-SkipX8632$/i } @ARGV);
push @SkippedTests, grep { /^arm/ } keys %TestArray if (grep { /^-SkipARM$/i } @ARGV);
push @SkippedTests, grep { /pic$/ } keys %TestArray if (grep { /^-SkipPIC$/i } @ARGV);

if ($#SkippedTests >= 0) {
  @DeletedTests = delete @TestArray{@SkippedTests};
  print "Skipping the following tests: ", join(" ", @SkippedTests), "\n";
  print "Running the following tests: ", join(" ", keys(%TestArray)), "\n";
} else {
  my $x = keys(%TestArray);
  print "Running all tests : $RUN_ALL_TESTS out of $x\n";
}

$TagSuccess = 1 if (grep { /^-TagSuccess$/ } @ARGV);
print "foo $Compile\n";
sub ReportTime {
  my (@Times) = @_;
  my $Message = shift @Times;
  print "*******************************************************************\n";
  print "$Message\n";
  print $Times[1] - $Times[0], " seconds\n";
  print "*******************************************************************\n";
}

if ($Clean) {
  &Shell("./tools/llvm/utman.sh clean", "wipeit");
  &Shell("gclient sync");
}

if ($Compile) {
  push @CompileTime, "Compile Time";
  push @CompileTime, time;

  if ($ResetMQ) {
    $ENV{UTMAN_RESET_MQ}="true";
  } else {
    $ENV{UTMAN_RESET_MQ}="false";
  }
  $ENV{LLVM_QPARENT_REV} =     $LLVMLog{rev};
  $ENV{LLVM_GCC_QPARENT_REV} = $LLVMGccLog{rev};
  $ENV{LLVM_MQ_REV} =          $LLVMMQRevLog{rev};
  $ENV{LLVM_GCC_MQ_REV} =      $LLVMMGccQRevLog{rev};

  print "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n";
  print "LLVM_QPARENT_REV    =$ENV{LLVM_QPARENT_REV} ${\(&GetRevName(%LLVMLog))}\n";
  print "LLVM_GCC_QPARENT_REV=$ENV{LLVM_GCC_QPARENT_REV} ${\(&GetRevName(%LLVMGccLog))}\n";
  print "LLVM_MQ_REV         =$ENV{LLVM_MQ_REV} ${\(&GetRevName(%LLVMMQRevLog))}\n";
  print "LLVM_GCC_MQ_REV     =$ENV{LLVM_GCC_MQ_REV} ${\(&GetRevName(%LLVMMGccQRevLog))}\n";
  print "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n";  

  &Shell("./tools/llvm/utman.sh show-config", "");
  &Shell("./tools/llvm/utman.sh everything-translator", "do it all");
  push @CompileTime, time;
  &ReportTime(@CompileTime);
}

if ($Download) {
  &Shell("./tools/llvm/utman.sh download-trusted", "");
}



if ($DoTest) {
  push @TestRunTime, "Test Run Time";
  push @TestRunTime, time;
  my $x = keys %TestArray;
  if ($x == $RUN_ALL_TESTS) {
    &Shell("./tools/llvm/utman-test.sh test-all", "");
  } else {
    &Shell("./tools/llvm/utman-test.sh test-x86-64", "") if (exists $TestArray{x8664});      
    &Shell("./tools/llvm/utman-test.sh test-x86-64-pic", "") if (exists  $TestArray{x8664pic});
    &Shell("./tools/llvm/utman-test.sh test-x86-32", "") if (exists  $TestArray{x8632});
    &Shell("./tools/llvm/utman-test.sh test-x86-32-pic", "") if (exists  $TestArray{x8632pic});      
    &Shell("./tools/llvm/utman-test.sh test-arm", "")   if (exists  $TestArray{arm});
    &Shell("./tools/llvm/utman-test.sh test-arm-pic", "") if (exists  $TestArray{armpic});

  }
  push @TestRunTime, time;
  &ReportTime(@TestRunTime);
}

{
  push @SpecTime, "Spec2K run time";
  push @SpecTime, time;
  my ($SETUP);
  my ($SPEC_TESTS) = "176.gcc 254.gap"; # 
  my ($OFFICIAL) = `(cd ~/Work/cpu2000-redhat64-ia32/; pwd)`;
  chomp $OFFICIAL;
  my @SpecSetUps = qw (SetupPnaclX8664Opt SetupPnaclArmOpt);
  @SpecSetUps = grep {!/x86/i} @SpecSetUps if (grep { /^-SkipX86/i } @ARGV );
  @SpecSetUps = grep {!/arm/i} @SpecSetUps if (grep { /^-Skiparm/i } @ARGV );
  print "Running the following SPEC setups ", join(" ", @SpecSetUps), "\n";

  if ($DoSpec) { 
    for $SETUP (@SpecSetUps) { 
      &Shell("(cd tests/spec2k; ./run_all.sh CleanBenchmarks ${SPEC_TESTS})", "clean gcc spec2k");
      &Shell("(cd tests/spec2k; ./run_all.sh PopulateFromSpecHarness ${OFFICIAL} ${SPEC_TESTS})", "clean specs");
      &Shell("(cd tests/spec2k; ./run_all.sh BuildAndRunBenchmarks  ${SETUP} ${SPEC_TESTS})", "run specs");
    }
    push @SpecTime, time;
    &ReportTime(@SpecTime);
  }
}

if ($DoTest && $DoSpec) {
  print "SUCCESS WITH REV $LLVMRev\n";
  print "Now saving the artifacts\n";


  &Shell("save-test-artifacts.pl $CurrRevTxt");


  &TagRepo($LLVMRepo, $LLVMLog{rev}, "TestAllPassed");
  &TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "TestAllPassed");
}

exit(0);
