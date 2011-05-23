#!/usr/bin/perl

use File::Basename;
# look for hg style patches and splits each chunk into a separate patch

sub SplitPatch () {
  my ($Dir, @Lines) = (@_);
  my $Line;
  my $DiffStart = '';
  my @Chunk;
  foreach $Line (@Lines) {
    if ($Line =~ /^diff /) {
      $DiffStart = $Line;
      &HandleChunk($Dir, @Chunk);
      # clear Chunk out for next bit
      @Chunk = ();
    }
    push @Chunk, $Line;
  }
  &HandleChunk($Dir, @Chunk)  if ($#Chunk >= 2);
}

sub HandleChunk() {
  my ($Dir, @Chunk) = (@_);
  my ($Seq) = 0;
  if ($#Chunk >= 2) {
    #$Chunk[0] =~ /^diff\s+(-\w+)?\s*(\S+)\s*(\S+)/;
    my (@x) = split(" ", $Chunk[0]);
    my ($File) = @x[$#x];
    #print "*** $Dir $File /// ",
    my ($filename, $directories, $suffix) = fileparse($File, qr/\.[^.]*/);
    $suffix =~ s/^\.//g;
    if ($filename eq '') {
      $filename = $suffix;
    }
    $PatchName =  "$Dir/$filename.patch";
    while (-e $PatchName) {
      $Seq++;
      $PatchName =  "$Dir/$filename${Seq}.patch";
      # print "  trying $PatchName\n"
    }
    print "$directories $PatchName\n";
    open (Patch, ">$PatchName") || die "Unable to save patch $File\n";
    print Patch @Chunk;
    close (Patch);
  }
}

$DST="/tmp/out";
if ($#ARGV >= 0) {
  $DST=$ARGV[0];
}

print "Using $DST";
`rm -rf $DST`;
`mkdir -p $DST`;
&SplitPatch($DST, <STDIN>);
