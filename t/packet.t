use strict;
use warnings;
use Test::More;
use Net::Quiche;

my $config = Net::Quiche->config(
    verify_peer                         => 0,
    initial_max_data                    => 1_000_000,
    initial_max_stream_data_bidi_local  => 100_000,
    initial_max_stream_data_bidi_remote => 100_000,
    initial_max_stream_data_uni         => 100_000,
    initial_max_streams_bidi            => 10,
    initial_max_streams_uni             => 10,
);

my $client = Net::Quiche::Connection->connect(
    config               => $config,
    server_name          => 'localhost',
    source_connection_id => 'client-packet-id',
    local                => ['127.0.0.1', 45_001],
    peer                 => ['127.0.0.1', 8_443],
);

my $datagram = $client->next_datagram;
my $header = Net::Quiche::Packet->header_info(
    $datagram->{data}, destination_connection_id_length => 16,
);

isa_ok($header, 'HASH');
is($header->{source_connection_id}, 'client-packet-id', 'Initial SCID is preserved');
is($header->{destination_connection_id}, $client->destination_connection_id,
    'Initial DCID is available for server bootstrap');
ok(Net::Quiche::Packet->version_is_supported($header->{version}),
    'Initial uses a quiche-supported QUIC version');
is($header->{token}, '', 'first Initial has no Retry token');

my $unsupported_packet = $datagram->{data};
my $unsupported_version = 0xface_b00c;
substr($unsupported_packet, 1, 4, pack('N', $unsupported_version));
my $unsupported_header = Net::Quiche::Packet->header_info(
    $unsupported_packet, destination_connection_id_length => 16,
);
is($unsupported_header->{version}, $unsupported_version,
    'unsupported version is visible to server routing');
ok(!Net::Quiche::Packet->version_is_supported($unsupported_header->{version}),
    'greased test version is unsupported');

my $negotiation = eval {
    Net::Quiche::Packet->negotiate_version(
        source_connection_id => $unsupported_header->{source_connection_id},
        destination_connection_id => $unsupported_header->{destination_connection_id},
    );
};
ok(defined $negotiation, 'version negotiation packet is generated')
    or diag($@ || 'negotiate_version() returned undef');
if (defined $negotiation) {
    my $negotiation_header = Net::Quiche::Packet->header_info(
        $negotiation, destination_connection_id_length => 16,
    );
    is($negotiation_header->{version}, 0,
        'version negotiation packet uses version zero');
    is($negotiation_header->{destination_connection_id},
        $unsupported_header->{source_connection_id},
        'version negotiation destination ID is the client source ID');
    is($negotiation_header->{source_connection_id},
        $unsupported_header->{destination_connection_id},
        'version negotiation source ID is the client destination ID');
}

my $empty_id_negotiation = eval {
    Net::Quiche::Packet->negotiate_version(
        source_connection_id => '', destination_connection_id => '',
    );
};
ok(defined $empty_id_negotiation,
    'zero-length connection IDs are accepted by the wire API');

for my $case (
    [missing => {source_connection_id => 'client'}],
    [unknown => {
        source_connection_id => 'client',
        destination_connection_id => 'server',
        typo => 1,
    }],
    [oversized => {
        source_connection_id => 'x' x 21,
        destination_connection_id => 'server',
    }],
) {
    my ($name, $arguments) = @{$case};
    my $accepted = eval {
        Net::Quiche::Packet->negotiate_version($arguments);
        1;
    };
    ok(!$accepted, "$name version negotiation arguments are rejected");
}

my $ok = eval { Net::Quiche::Packet->header_info(''); 1 };
ok(!$ok, 'malformed packet is rejected');
like($@, qr/parse QUIC packet header/, 'packet parser error names the operation');

done_testing;
