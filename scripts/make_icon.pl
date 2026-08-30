#!/usr/bin/perl
use strict;
use warnings;

@ARGV == 2 or die "usage: make_icon.pl ICONSET OUTPUT\n";
my ($iconset, $output) = @ARGV;

# Use the scale-aware ICNS representations for small icons. On current macOS,
# PNG payloads stored in the legacy icp4/icp5/icp6 slots are interpreted as
# legacy bitmap data and render as an opaque, incorrectly scaled icon. ic11 and
# ic12 supply the same 32px and 64px data without that decoding ambiguity; the
# system downsamples them for smaller display sizes when needed.
my @representations = (
    ["ic07", "icon_128x128.png"],
    ["ic08", "icon_256x256.png"],
    ["ic09", "icon_512x512.png"],
    ["ic10", "icon_512x512\@2x.png"],
    ["ic11", "icon_16x16\@2x.png"],
    ["ic12", "icon_32x32\@2x.png"],
    ["ic13", "icon_128x128\@2x.png"],
    ["ic14", "icon_256x256\@2x.png"],
);

my @chunks;
for my $representation (@representations) {
    my ($type, $filename) = @{$representation};
    open my $input, "<:raw", "$iconset/$filename"
        or die "cannot read $iconset/$filename: $!\n";
    local $/;
    my $data = <$input>;
    close $input;
    push @chunks, [$type, $data];
}

my $toc = join "", map { $_->[0] . pack("N", length($_->[1]) + 8) } @chunks;
my $body = "TOC " . pack("N", length($toc) + 8) . $toc;
$body .= join "", map { $_->[0] . pack("N", length($_->[1]) + 8) . $_->[1] } @chunks;

open my $destination, ">:raw", $output or die "cannot write $output: $!\n";
print {$destination} "icns", pack("N", length($body) + 8), $body;
close $destination;
