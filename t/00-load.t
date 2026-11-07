use strict;
use warnings;
use Test::More;

use_ok('Net::Quiche::XS');
use_ok('Net::Quiche');
use_ok('Net::Quiche::Config');
use_ok('Net::Quiche::Connection');
use_ok('Net::Quiche::HTTP3');
use_ok('Net::Quiche::HTTP3::Client');
use_ok('Net::Quiche::HTTP3::Exchange');
use_ok('Net::Quiche::HTTP3::Proxy::SOCKS5');
use_ok('Net::Quiche::HTTP3::Response');
use_ok('Net::Quiche::Packet');
use_ok('PAGI::Server::Protocol::HTTP3');
use_ok('PAGI::Server::HTTP3');
use_ok('PAGI::Server::HTTP3::ConnectionState');
use_ok('PAGI::Test::HTTP3Client');
can_ok('Net::Quiche::XS', 'version');
can_ok('Net::Quiche', 'version');
can_ok('Net::Quiche::Config', qw(
    new application_protocols max_idle_timeout verify_locations_file
    verify_locations_directory
));
can_ok('Net::Quiche::Connection', qw(
    connect accept receive_datagram next_datagram close shutdown_stream
    is_draining http3 local_error peer_error
));
can_ok('Net::Quiche::HTTP3', qw(
    poll send_request send_response send_body send_goaway
));
can_ok('Net::Quiche::HTTP3::Client', qw(
    new get post request start_request stop connection_count active_requests
));
can_ok('Net::Quiche::HTTP3::Exchange', qw(
    write finish_request response stream_id cancel
));
can_ok('Net::Quiche::HTTP3::Response', qw(
    status http_version headers header header_values is_success
    read slurp body is_complete effective_uri redirect_history
));
can_ok('Net::Quiche::Packet', qw(header_info version_is_supported negotiate_version));
can_ok('PAGI::Server::Protocol::HTTP3', qw(
    new drain_events send_goaway next_request_stream_id disconnect
));
can_ok('PAGI::Server::HTTP3', qw(
    new listen run goaway shutdown stop bound_port connection_count
));
can_ok('PAGI::Server::HTTP3::ConnectionState', qw(
    new is_connected disconnect_reason on_disconnect response_started
    on_complete response_complete disconnect_future
));
can_ok('PAGI::Test::HTTP3Client', qw(
    new get post request base_uri stop
));

done_testing;
