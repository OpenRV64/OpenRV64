#!/usr/bin/env perl
use strict;
use warnings;

@ARGV >= 2 or die "usage: pc-sample-histogram.pl SAMPLES SYMBOL_MAP...\n";
my $sample_path = shift @ARGV;
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
my (%count, $total);
while (my $line = <$samples>) {
    next if $line =~ /^#/;
    my (undef, $pc) = split /\s+/, $line;
    next unless defined $pc;
    ++$count{resolve_pc($pc)};
    ++$total;
}
close $samples or die "close $sample_path: $!\n";

print "# samples=$total\n";
print "count\tpercent\tfunction\n";
for my $name (sort { $count{$b} <=> $count{$a} || $a cmp $b } keys %count) {
    printf "%u\t%.3f\t%s\n", $count{$name},
        $total ? 100.0 * $count{$name} / $total : 0.0, $name;
}
