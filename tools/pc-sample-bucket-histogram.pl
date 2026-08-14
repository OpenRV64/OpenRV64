#!/usr/bin/env perl
use strict;
use warnings;

@ARGV >= 3 or die
    "usage: pc-sample-bucket-histogram.pl SAMPLES BUCKET_CYCLES SYMBOL_MAP...\n";
my $sample_path = shift @ARGV;
my $bucket_cycles = shift @ARGV;
$bucket_cycles =~ /^\d+$/ && $bucket_cycles > 0 or
    die "BUCKET_CYCLES must be a positive integer\n";
my @symbols;

for my $map_path (@ARGV) {
    open my $map, '<', $map_path or die "open $map_path: $!\n";
    while (my $line = <$map>) {
        chomp $line;
        my ($address, $type, $name) = split /\s+/, $line, 3;
        next unless defined $name && $type =~ /^[tTwW]$/;
        $address = lc $address;
        $address =~ s/^0x//;
        $address = ('0' x (16 - length $address)) . $address;
        push @symbols, [$address, $name];
    }
    close $map or die "close $map_path: $!\n";
}

@symbols = sort {
    $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1]
} @symbols;

sub resolve_pc {
    my ($pc) = @_;
    $pc = lc $pc;
    $pc =~ s/^0x//;
    $pc = ('0' x (16 - length $pc)) . $pc;
    my ($low, $high) = (0, scalar @symbols);
    while ($low < $high) {
        my $mid = int(($low + $high) / 2);
        if ($symbols[$mid][0] le $pc) {
            $low = $mid + 1;
        } else {
            $high = $mid;
        }
    }
    return '<unknown>' if $low == 0;
    return $symbols[$low - 1][1];
}

open my $samples, '<', $sample_path or die "open $sample_path: $!\n";
my (%count, %total);
while (my $line = <$samples>) {
    next if $line =~ /^#/;
    my ($cycle, $pc) = split /\s+/, $line;
    next unless defined $pc && $cycle =~ /^\d+$/;

    # Define buckets as (start, end], so a 10K-period trace contributes
    # exactly 100 samples to every complete 1M-cycle interval.
    my $bucket = $cycle > 0 ? int(($cycle - 1) / $bucket_cycles) : 0;
    my $name = resolve_pc($pc);
    ++$count{$bucket}{$name};
    ++$total{$bucket};
}
close $samples or die "close $sample_path: $!\n";

print "# bucket_cycles=$bucket_cycles intervals=(start_cycle,end_cycle]\n";
print "bucket\tstart_cycle_exclusive\tend_cycle_inclusive\tsamples\tcount\tpercent\tfunction\n";
for my $bucket (sort { $a <=> $b } keys %total) {
    my $start = $bucket * $bucket_cycles;
    my $end = $start + $bucket_cycles;
    for my $name (sort {
        $count{$bucket}{$b} <=> $count{$bucket}{$a} || $a cmp $b
    } keys %{$count{$bucket}}) {
        printf "%u\t%u\t%u\t%u\t%u\t%.3f\t%s\n",
            $bucket, $start, $end, $total{$bucket},
            $count{$bucket}{$name},
            100.0 * $count{$bucket}{$name} / $total{$bucket}, $name;
    }
}
