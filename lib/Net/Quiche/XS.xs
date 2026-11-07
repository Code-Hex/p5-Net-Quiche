#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <quiche.h>
#include <sys/socket.h>

#define NET_QUICHE_MAX_DATAGRAM_SIZE 1350

typedef struct {
    quiche_config *config;
} net_quiche_config_handle;

typedef struct {
    quiche_conn *conn;
} net_quiche_connection_handle;

typedef struct {
    quiche_h3_conn *conn;
} net_quiche_h3_handle;

static SV *
net_quiche_config_wrap(pTHX_ quiche_config *config, const char *class_name)
{
    net_quiche_config_handle *handle;
    SV *inner;
    SV *object;

    Newxz(handle, 1, net_quiche_config_handle);
    handle->config = config;
    inner = newSViv(PTR2IV(handle));
    object = newRV_noinc(inner);
    sv_bless(object, gv_stashpv(class_name, GV_ADD));
    SvREADONLY_on(inner);

    return object;
}

static net_quiche_config_handle *
net_quiche_config_handle_from_sv(pTHX_ SV *object)
{
    SV *inner;
    net_quiche_config_handle *handle;

    if (!sv_isobject(object) ||
            !sv_derived_from(object, "Net::Quiche::Config")) {
        croak("Expected a Net::Quiche::Config object");
    }

    inner = SvRV(object);
    handle = INT2PTR(net_quiche_config_handle *, SvIV(inner));
    if (handle == NULL || handle->config == NULL) {
        croak("Net::Quiche::Config object has already been destroyed");
    }

    return handle;
}

static SV *
net_quiche_pointer_wrap(pTHX_ void *pointer, const char *class_name)
{
    SV *inner = newSViv(PTR2IV(pointer));
    SV *object = newRV_noinc(inner);

    sv_bless(object, gv_stashpv(class_name, GV_ADD));
    SvREADONLY_on(inner);
    return object;
}

static net_quiche_connection_handle *
net_quiche_connection_handle_from_sv(pTHX_ SV *object)
{
    net_quiche_connection_handle *handle;

    if (!sv_isobject(object) ||
            !sv_derived_from(object, "Net::Quiche::XS::Connection")) {
        croak("Expected a native Net::Quiche connection object");
    }

    handle = INT2PTR(net_quiche_connection_handle *, SvIV(SvRV(object)));
    if (handle == NULL || handle->conn == NULL) {
        croak("Native Net::Quiche connection has already been destroyed");
    }
    return handle;
}

static net_quiche_h3_handle *
net_quiche_h3_handle_from_sv(pTHX_ SV *object)
{
    net_quiche_h3_handle *handle;

    if (!sv_isobject(object) ||
            !sv_derived_from(object, "Net::Quiche::XS::HTTP3")) {
        croak("Expected a native Net::Quiche HTTP/3 object");
    }

    handle = INT2PTR(net_quiche_h3_handle *, SvIV(SvRV(object)));
    if (handle == NULL || handle->conn == NULL) {
        croak("Native Net::Quiche HTTP/3 object has already been destroyed");
    }
    return handle;
}

static void
net_quiche_sockaddr_from_sv(pTHX_ SV *packed, struct sockaddr_storage *out,
                            socklen_t *out_len, const char *name)
{
    STRLEN length;
    const char *bytes = SvPVbyte(packed, length);

    if (length == 0 || length > sizeof(*out)) {
        croak("Invalid packed %s socket address", name);
    }
    Zero(out, 1, struct sockaddr_storage);
    Copy(bytes, out, length, char);
    *out_len = (socklen_t) length;
}

static quiche_h3_header *
net_quiche_headers_from_av(pTHX_ AV *input, size_t *count)
{
    SSize_t last = av_len(input);
    quiche_h3_header *headers;
    SSize_t i;

    *count = last < 0 ? 0 : (size_t) last + 1;
    if (*count == 0) {
        return NULL;
    }
    Newxz(headers, *count, quiche_h3_header);

    for (i = 0; i <= last; i++) {
        SV **item = av_fetch(input, i, 0);
        AV *pair;
        SV **name;
        SV **value;
        STRLEN name_len;
        STRLEN value_len;

        if (item == NULL || !SvROK(*item) ||
                SvTYPE(SvRV(*item)) != SVt_PVAV) {
            Safefree(headers);
            croak("HTTP/3 headers must contain array references");
        }
        pair = (AV *) SvRV(*item);
        name = av_fetch(pair, 0, 0);
        value = av_fetch(pair, 1, 0);
        if (name == NULL || value == NULL || av_len(pair) != 1) {
            Safefree(headers);
            croak("Each HTTP/3 header must contain exactly two values");
        }
        headers[i].name = (const uint8_t *) SvPVbyte(*name, name_len);
        headers[i].name_len = name_len;
        headers[i].value = (const uint8_t *) SvPVbyte(*value, value_len);
        headers[i].value_len = value_len;
    }
    return headers;
}

static int
net_quiche_collect_header(uint8_t *name, size_t name_len,
                          uint8_t *value, size_t value_len, void *argp)
{
    dTHX;
    AV *headers = (AV *) argp;
    AV *pair = newAV();

    av_push(pair, newSVpvn((const char *) name, name_len));
    av_push(pair, newSVpvn((const char *) value, value_len));
    av_push(headers, newRV_noinc((SV *) pair));
    return 0;
}

MODULE = Net::Quiche::XS    PACKAGE = Net::Quiche::XS

PROTOTYPES: DISABLE

SV *
version()
    CODE:
        /* quiche owns the static string; Perl owns this copy. */
        RETVAL = newSVpv(quiche_version(), 0);
    OUTPUT:
        RETVAL

SV *
_packet_header_info(packet, destination_connection_id_length)
        SV *packet
        UV destination_connection_id_length
    PREINIT:
        STRLEN packet_len;
        const uint8_t *packet_bytes;
        uint32_t version;
        uint8_t type;
        uint8_t source_id[QUICHE_MAX_CONN_ID_LEN];
        size_t source_id_len = sizeof(source_id);
        uint8_t destination_id[QUICHE_MAX_CONN_ID_LEN];
        size_t destination_id_len = sizeof(destination_id);
        uint8_t *token;
        size_t token_len;
        int status;
        AV *output;
    CODE:
        if (destination_connection_id_length > QUICHE_MAX_CONN_ID_LEN) {
            croak("destination_connection_id_length exceeds quiche maximum");
        }
        packet_bytes = (const uint8_t *) SvPVbyte(packet, packet_len);
        token_len = packet_len;
        Newx(token, token_len ? token_len : 1, uint8_t);
        status = quiche_header_info(
            packet_bytes, packet_len, (size_t) destination_connection_id_length,
            &version, &type,
            source_id, &source_id_len,
            destination_id, &destination_id_len,
            token, &token_len);
        if (status < 0) {
            Safefree(token);
            croak("Failed to parse QUIC packet header: quiche error %d", status);
        }
        output = newAV();
        av_push(output, newSVuv((UV) version));
        av_push(output, newSVuv((UV) type));
        av_push(output, newSVpvn((const char *) source_id, source_id_len));
        av_push(output, newSVpvn((const char *) destination_id, destination_id_len));
        av_push(output, newSVpvn((const char *) token, token_len));
        Safefree(token);
        RETVAL = newRV_noinc((SV *) output);
    OUTPUT:
        RETVAL

bool
_version_is_supported(version)
        UV version
    CODE:
        RETVAL = quiche_version_is_supported((uint32_t) version);
    OUTPUT:
        RETVAL

SV *
_packet_negotiate_version(source_connection_id, destination_connection_id)
        SV *source_connection_id
        SV *destination_connection_id
    PREINIT:
        STRLEN source_id_len;
        STRLEN destination_id_len;
        const uint8_t *source_id;
        const uint8_t *destination_id;
        uint8_t output[NET_QUICHE_MAX_DATAGRAM_SIZE];
        ssize_t written;
    CODE:
        source_id = (const uint8_t *) SvPVbyte(
            source_connection_id, source_id_len);
        destination_id = (const uint8_t *) SvPVbyte(
            destination_connection_id, destination_id_len);
        written = quiche_negotiate_version(
            source_id, source_id_len,
            destination_id, destination_id_len,
            output, sizeof(output));
        if (written < 0) {
            croak("Failed to generate QUIC version negotiation packet: quiche error %ld",
                (long) written);
        }
        RETVAL = newSVpvn((const char *) output, (STRLEN) written);
    OUTPUT:
        RETVAL

SV *
_config_new(class_name)
        const char *class_name
    PREINIT:
        quiche_config *config;
    CODE:
        config = quiche_config_new(QUICHE_PROTOCOL_VERSION);
        if (config == NULL) {
            croak("quiche_config_new() failed for QUICHE_PROTOCOL_VERSION");
        }
        RETVAL = net_quiche_config_wrap(aTHX_ config, class_name);
    OUTPUT:
        RETVAL

int
_config_load_cert_chain(config_object, path)
        SV *config_object
        SV *path
    PREINIT:
        STRLEN path_len;
        const char *path_bytes;
    CODE:
        path_bytes = SvPVutf8(path, path_len);
        RETVAL = quiche_config_load_cert_chain_from_pem_file(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            path_bytes);
    OUTPUT:
        RETVAL

int
_config_load_private_key(config_object, path)
        SV *config_object
        SV *path
    PREINIT:
        STRLEN path_len;
        const char *path_bytes;
    CODE:
        path_bytes = SvPVutf8(path, path_len);
        RETVAL = quiche_config_load_priv_key_from_pem_file(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            path_bytes);
    OUTPUT:
        RETVAL

int
_config_load_verify_locations_from_file(config_object, path)
        SV *config_object
        SV *path
    PREINIT:
        STRLEN path_len;
        const char *path_bytes;
    CODE:
        path_bytes = SvPVutf8(path, path_len);
        RETVAL = quiche_config_load_verify_locations_from_file(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            path_bytes);
    OUTPUT:
        RETVAL

int
_config_load_verify_locations_from_directory(config_object, path)
        SV *config_object
        SV *path
    PREINIT:
        STRLEN path_len;
        const char *path_bytes;
    CODE:
        path_bytes = SvPVutf8(path, path_len);
        RETVAL = quiche_config_load_verify_locations_from_directory(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            path_bytes);
    OUTPUT:
        RETVAL

int
_config_set_application_protocols(config_object, wire_protocols)
        SV *config_object
        SV *wire_protocols
    PREINIT:
        STRLEN wire_len;
        const uint8_t *wire_bytes;
    CODE:
        wire_bytes = (const uint8_t *) SvPVbyte(wire_protocols, wire_len);
        RETVAL = quiche_config_set_application_protos(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            wire_bytes, wire_len);
    OUTPUT:
        RETVAL

void
_config_verify_peer(config_object, value)
        SV *config_object
        bool value
    CODE:
        quiche_config_verify_peer(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            value);

void
_config_set_max_idle_timeout(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_max_idle_timeout(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (uint64_t) value);

void
_config_set_max_recv_udp_payload_size(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_max_recv_udp_payload_size(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (size_t) value);

void
_config_set_max_send_udp_payload_size(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_max_send_udp_payload_size(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (size_t) value);

void
_config_set_initial_max_data(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_initial_max_data(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (uint64_t) value);

void
_config_set_initial_max_stream_data_bidi_local(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_initial_max_stream_data_bidi_local(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (uint64_t) value);

void
_config_set_initial_max_stream_data_bidi_remote(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_initial_max_stream_data_bidi_remote(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (uint64_t) value);

void
_config_set_initial_max_stream_data_uni(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_initial_max_stream_data_uni(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (uint64_t) value);

void
_config_set_initial_max_streams_bidi(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_initial_max_streams_bidi(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (uint64_t) value);

void
_config_set_initial_max_streams_uni(config_object, value)
        SV *config_object
        UV value
    CODE:
        quiche_config_set_initial_max_streams_uni(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            (uint64_t) value);

void
_config_set_disable_active_migration(config_object, value)
        SV *config_object
        bool value
    CODE:
        quiche_config_set_disable_active_migration(
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config,
            value);

SV *
_connection_connect(config_object, server_name, source_id, local_address, peer_address)
        SV *config_object
        SV *server_name
        SV *source_id
        SV *local_address
        SV *peer_address
    PREINIT:
        STRLEN server_name_len;
        STRLEN source_id_len;
        const char *server_name_bytes;
        const uint8_t *source_id_bytes;
        struct sockaddr_storage local;
        struct sockaddr_storage peer;
        socklen_t local_len;
        socklen_t peer_len;
        quiche_conn *conn;
        net_quiche_connection_handle *handle;
    CODE:
        server_name_bytes = SvOK(server_name)
            ? SvPVutf8(server_name, server_name_len) : NULL;
        source_id_bytes = (const uint8_t *) SvPVbyte(source_id, source_id_len);
        net_quiche_sockaddr_from_sv(aTHX_ local_address, &local, &local_len, "local");
        net_quiche_sockaddr_from_sv(aTHX_ peer_address, &peer, &peer_len, "peer");
        conn = quiche_connect(
            server_name_bytes, source_id_bytes, source_id_len,
            (struct sockaddr *) &local, local_len,
            (struct sockaddr *) &peer, peer_len,
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config);
        if (conn == NULL) {
            croak("quiche_connect() failed");
        }
        Newxz(handle, 1, net_quiche_connection_handle);
        handle->conn = conn;
        RETVAL = net_quiche_pointer_wrap(
            aTHX_ handle, "Net::Quiche::XS::Connection");
    OUTPUT:
        RETVAL

SV *
_connection_accept(config_object, source_id, original_destination_id, local_address, peer_address)
        SV *config_object
        SV *source_id
        SV *original_destination_id
        SV *local_address
        SV *peer_address
    PREINIT:
        STRLEN source_id_len;
        STRLEN original_destination_id_len = 0;
        const uint8_t *source_id_bytes;
        const uint8_t *original_destination_id_bytes = NULL;
        struct sockaddr_storage local;
        struct sockaddr_storage peer;
        socklen_t local_len;
        socklen_t peer_len;
        quiche_conn *conn;
        net_quiche_connection_handle *handle;
    CODE:
        source_id_bytes = (const uint8_t *) SvPVbyte(source_id, source_id_len);
        if (SvOK(original_destination_id)) {
            original_destination_id_bytes = (const uint8_t *)
                SvPVbyte(original_destination_id, original_destination_id_len);
        }
        net_quiche_sockaddr_from_sv(aTHX_ local_address, &local, &local_len, "local");
        net_quiche_sockaddr_from_sv(aTHX_ peer_address, &peer, &peer_len, "peer");
        conn = quiche_accept(
            source_id_bytes, source_id_len,
            original_destination_id_bytes, original_destination_id_len,
            (struct sockaddr *) &local, local_len,
            (struct sockaddr *) &peer, peer_len,
            net_quiche_config_handle_from_sv(aTHX_ config_object)->config);
        if (conn == NULL) {
            croak("quiche_accept() failed");
        }
        Newxz(handle, 1, net_quiche_connection_handle);
        handle->conn = conn;
        RETVAL = net_quiche_pointer_wrap(
            aTHX_ handle, "Net::Quiche::XS::Connection");
    OUTPUT:
        RETVAL

SV *
_connection_receive(native_connection, packet, from_address, to_address)
        SV *native_connection
        SV *packet
        SV *from_address
        SV *to_address
    PREINIT:
        STRLEN packet_len;
        const uint8_t *packet_bytes;
        uint8_t *mutable_packet;
        struct sockaddr_storage from;
        struct sockaddr_storage to;
        socklen_t from_len;
        socklen_t to_len;
        quiche_recv_info info;
        ssize_t result;
    CODE:
        packet_bytes = (const uint8_t *) SvPVbyte(packet, packet_len);
        Newx(mutable_packet, packet_len ? packet_len : 1, uint8_t);
        if (packet_len) {
            Copy(packet_bytes, mutable_packet, packet_len, uint8_t);
        }
        net_quiche_sockaddr_from_sv(aTHX_ from_address, &from, &from_len, "from");
        net_quiche_sockaddr_from_sv(aTHX_ to_address, &to, &to_len, "to");
        info.from = (struct sockaddr *) &from;
        info.from_len = from_len;
        info.to = (struct sockaddr *) &to;
        info.to_len = to_len;
        result = quiche_conn_recv(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            mutable_packet, packet_len, &info);
        Safefree(mutable_packet);
        if (result < 0) {
            croak("quiche_conn_recv() failed: %ld", (long) result);
        }
        RETVAL = newSVuv((UV) result);
    OUTPUT:
        RETVAL

SV *
_connection_next_datagram(native_connection)
        SV *native_connection
    PREINIT:
        quiche_conn *conn;
        size_t capacity;
        uint8_t *buffer;
        quiche_send_info info;
        ssize_t result;
        AV *output;
    CODE:
        conn = net_quiche_connection_handle_from_sv(
            aTHX_ native_connection)->conn;
        capacity = quiche_conn_max_send_udp_payload_size(conn);
        if (capacity < 1200) {
            capacity = 1200;
        }
        Newx(buffer, capacity, uint8_t);
        result = quiche_conn_send(conn, buffer, capacity, &info);
        if (result == QUICHE_ERR_DONE) {
            Safefree(buffer);
            XSRETURN_UNDEF;
        }
        if (result < 0) {
            Safefree(buffer);
            croak("quiche_conn_send() failed: %ld", (long) result);
        }
        output = newAV();
        av_push(output, newSVpvn((const char *) buffer, (STRLEN) result));
        av_push(output, newSVpvn((const char *) &info.from, info.from_len));
        av_push(output, newSVpvn((const char *) &info.to, info.to_len));
        Safefree(buffer);
        RETVAL = newRV_noinc((SV *) output);
    OUTPUT:
        RETVAL

UV
_connection_timeout_ms(native_connection)
        SV *native_connection
    CODE:
        RETVAL = (UV) quiche_conn_timeout_as_millis(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn);
    OUTPUT:
        RETVAL

void
_connection_on_timeout(native_connection)
        SV *native_connection
    CODE:
        quiche_conn_on_timeout(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn);

bool
_connection_close(native_connection, application, error_code, reason)
        SV *native_connection
        bool application
        UV error_code
        SV *reason
    PREINIT:
        STRLEN reason_len;
        const uint8_t *reason_bytes;
        int result;
    CODE:
        reason_bytes = (const uint8_t *) SvPVbyte(reason, reason_len);
        result = quiche_conn_close(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            application, (uint64_t) error_code, reason_bytes, reason_len);
        if (result == QUICHE_ERR_DONE) {
            RETVAL = 0;
        } else if (result < 0) {
            croak("quiche_conn_close() failed: %d", result);
        } else {
            RETVAL = 1;
        }
    OUTPUT:
        RETVAL

bool
_connection_stream_shutdown(native_connection, stream_id, direction, error_code)
        SV *native_connection
        UV stream_id
        UV direction
        UV error_code
    PREINIT:
        int result;
    CODE:
        if (direction > QUICHE_SHUTDOWN_WRITE) {
            croak("QUIC stream shutdown direction must be read or write");
        }
        result = quiche_conn_stream_shutdown(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            (uint64_t) stream_id, (enum quiche_shutdown) direction,
            (uint64_t) error_code);
        if (result == QUICHE_ERR_DONE) {
            RETVAL = 0;
        } else if (result < 0) {
            croak("quiche_conn_stream_shutdown() failed: %d", result);
        } else {
            RETVAL = 1;
        }
    OUTPUT:
        RETVAL

bool
_connection_is_established(native_connection)
        SV *native_connection
    CODE:
        RETVAL = quiche_conn_is_established(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn);
    OUTPUT:
        RETVAL

bool
_connection_is_closed(native_connection)
        SV *native_connection
    CODE:
        RETVAL = quiche_conn_is_closed(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn);
    OUTPUT:
        RETVAL

bool
_connection_is_draining(native_connection)
        SV *native_connection
    CODE:
        RETVAL = quiche_conn_is_draining(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn);
    OUTPUT:
        RETVAL

SV *
_connection_error(native_connection, local)
        SV *native_connection
        bool local
    PREINIT:
        bool is_app;
        uint64_t error_code;
        const uint8_t *reason;
        size_t reason_len;
        bool present;
        AV *output;
    CODE:
        if (local) {
            present = quiche_conn_local_error(
                net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
                &is_app, &error_code, &reason, &reason_len);
        } else {
            present = quiche_conn_peer_error(
                net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
                &is_app, &error_code, &reason, &reason_len);
        }
        if (!present) {
            XSRETURN_UNDEF;
        }
        output = newAV();
        av_push(output, newSViv(is_app ? 1 : 0));
        av_push(output, newSVuv((UV) error_code));
        av_push(output, newSVpvn((const char *) reason, reason_len));
        RETVAL = newRV_noinc((SV *) output);
    OUTPUT:
        RETVAL

SV *
_connection_source_id(native_connection)
        SV *native_connection
    PREINIT:
        const uint8_t *bytes;
        size_t length;
    CODE:
        quiche_conn_source_id(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            &bytes, &length);
        RETVAL = newSVpvn((const char *) bytes, length);
    OUTPUT:
        RETVAL

SV *
_connection_destination_id(native_connection)
        SV *native_connection
    PREINIT:
        const uint8_t *bytes;
        size_t length;
    CODE:
        quiche_conn_destination_id(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            &bytes, &length);
        RETVAL = newSVpvn((const char *) bytes, length);
    OUTPUT:
        RETVAL

SV *
_connection_application_protocol(native_connection)
        SV *native_connection
    PREINIT:
        const uint8_t *bytes;
        size_t length;
    CODE:
        quiche_conn_application_proto(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            &bytes, &length);
        RETVAL = newSVpvn((const char *) bytes, length);
    OUTPUT:
        RETVAL

SV *
_h3_new(native_connection)
        SV *native_connection
    PREINIT:
        quiche_h3_config *config;
        quiche_h3_conn *conn;
        net_quiche_h3_handle *handle;
    CODE:
        config = quiche_h3_config_new();
        if (config == NULL) {
            croak("quiche_h3_config_new() failed");
        }
        conn = quiche_h3_conn_new_with_transport(
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            config);
        quiche_h3_config_free(config);
        if (conn == NULL) {
            croak("quiche_h3_conn_new_with_transport() failed");
        }
        Newxz(handle, 1, net_quiche_h3_handle);
        handle->conn = conn;
        RETVAL = net_quiche_pointer_wrap(
            aTHX_ handle, "Net::Quiche::XS::HTTP3");
    OUTPUT:
        RETVAL

SV *
_h3_poll(native_h3, native_connection)
        SV *native_h3
        SV *native_connection
    PREINIT:
        quiche_h3_event *event = NULL;
        int64_t stream_id;
        enum quiche_h3_event_type type;
        AV *output;
        AV *headers;
        int status;
    CODE:
        stream_id = quiche_h3_conn_poll(
            net_quiche_h3_handle_from_sv(aTHX_ native_h3)->conn,
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            &event);
        if (stream_id == QUICHE_H3_ERR_DONE) {
            XSRETURN_UNDEF;
        }
        if (stream_id < 0) {
            croak("quiche_h3_conn_poll() failed: %lld", (long long) stream_id);
        }
        type = quiche_h3_event_type(event);
        output = newAV();
        av_push(output, newSViv((IV) type));
        av_push(output, newSVuv((UV) stream_id));
        if (type == QUICHE_H3_EVENT_HEADERS) {
            headers = newAV();
            status = quiche_h3_event_for_each_header(
                event, net_quiche_collect_header, headers);
            if (status != 0) {
                SvREFCNT_dec((SV *) headers);
                quiche_h3_event_free(event);
                SvREFCNT_dec((SV *) output);
                croak("quiche_h3_event_for_each_header() failed: %d", status);
            }
            av_push(output, newRV_noinc((SV *) headers));
            av_push(output, newSViv(
                quiche_h3_event_headers_has_more_frames(event) ? 1 : 0));
        }
        quiche_h3_event_free(event);
        RETVAL = newRV_noinc((SV *) output);
    OUTPUT:
        RETVAL

SV *
_h3_receive_body(native_h3, native_connection, stream_id, capacity)
        SV *native_h3
        SV *native_connection
        UV stream_id
        UV capacity
    PREINIT:
        uint8_t *buffer;
        ssize_t result;
    CODE:
        if (capacity == 0) {
            croak("HTTP/3 body read capacity must be greater than zero");
        }
        Newx(buffer, capacity, uint8_t);
        result = quiche_h3_recv_body(
            net_quiche_h3_handle_from_sv(aTHX_ native_h3)->conn,
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            (uint64_t) stream_id, buffer, (size_t) capacity);
        if (result == QUICHE_H3_ERR_DONE) {
            Safefree(buffer);
            XSRETURN_UNDEF;
        }
        if (result < 0) {
            Safefree(buffer);
            croak("quiche_h3_recv_body() failed: %ld", (long) result);
        }
        RETVAL = newSVpvn((const char *) buffer, (STRLEN) result);
        Safefree(buffer);
    OUTPUT:
        RETVAL

SV *
_h3_send_request(native_h3, native_connection, header_list, final)
        SV *native_h3
        SV *native_connection
        AV *header_list
        bool final
    PREINIT:
        quiche_h3_header *headers;
        size_t header_count;
        int64_t result;
    CODE:
        headers = net_quiche_headers_from_av(aTHX_ header_list, &header_count);
        result = quiche_h3_send_request(
            net_quiche_h3_handle_from_sv(aTHX_ native_h3)->conn,
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            headers, header_count, final);
        Safefree(headers);
        if (result == QUICHE_H3_ERR_DONE ||
                result == QUICHE_H3_ERR_STREAM_BLOCKED) {
            XSRETURN_UNDEF;
        }
        if (result < 0) {
            croak("quiche_h3_send_request() failed: %lld", (long long) result);
        }
        RETVAL = newSVuv((UV) result);
    OUTPUT:
        RETVAL

SV *
_h3_send_response(native_h3, native_connection, stream_id, header_list, final)
        SV *native_h3
        SV *native_connection
        UV stream_id
        AV *header_list
        bool final
    PREINIT:
        quiche_h3_header *headers;
        size_t header_count;
        int result;
    CODE:
        headers = net_quiche_headers_from_av(aTHX_ header_list, &header_count);
        result = quiche_h3_send_response(
            net_quiche_h3_handle_from_sv(aTHX_ native_h3)->conn,
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            (uint64_t) stream_id, headers, header_count, final);
        Safefree(headers);
        if (result == QUICHE_H3_ERR_DONE ||
                result == QUICHE_H3_ERR_STREAM_BLOCKED) {
            XSRETURN_UNDEF;
        }
        if (result < 0) {
            croak("quiche_h3_send_response() failed: %d", result);
        }
        RETVAL = newSViv(1);
    OUTPUT:
        RETVAL

SV *
_h3_send_body(native_h3, native_connection, stream_id, body, final)
        SV *native_h3
        SV *native_connection
        UV stream_id
        SV *body
        bool final
    PREINIT:
        STRLEN body_len;
        const uint8_t *body_bytes;
        ssize_t result;
    CODE:
        body_bytes = (const uint8_t *) SvPVbyte(body, body_len);
        result = quiche_h3_send_body(
            net_quiche_h3_handle_from_sv(aTHX_ native_h3)->conn,
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            (uint64_t) stream_id, body_bytes, body_len, final);
        if (result == QUICHE_H3_ERR_DONE ||
                result == QUICHE_H3_ERR_STREAM_BLOCKED) {
            XSRETURN_UNDEF;
        }
        if (result < 0) {
            croak("quiche_h3_send_body() failed: %ld", (long) result);
        }
        RETVAL = newSViv((IV) result);
    OUTPUT:
        RETVAL

SV *
_h3_send_goaway(native_h3, native_connection, id)
        SV *native_h3
        SV *native_connection
        UV id
    PREINIT:
        int result;
    CODE:
        result = quiche_h3_send_goaway(
            net_quiche_h3_handle_from_sv(aTHX_ native_h3)->conn,
            net_quiche_connection_handle_from_sv(aTHX_ native_connection)->conn,
            (uint64_t) id);
        if (result == QUICHE_H3_ERR_DONE ||
                result == QUICHE_H3_ERR_STREAM_BLOCKED ||
                result == QUICHE_H3_TRANSPORT_ERR_DONE) {
            XSRETURN_UNDEF;
        }
        if (result < 0) {
            croak("quiche_h3_send_goaway() failed: %d", result);
        }
        RETVAL = newSViv(1);
    OUTPUT:
        RETVAL

MODULE = Net::Quiche::XS    PACKAGE = Net::Quiche::Config

void
DESTROY(config_object)
        SV *config_object
    PREINIT:
        SV *inner;
        net_quiche_config_handle *handle;
    CODE:
        if (SvROK(config_object)) {
            inner = SvRV(config_object);
            handle = INT2PTR(net_quiche_config_handle *, SvIV(inner));
            if (handle != NULL) {
                if (handle->config != NULL) {
                    quiche_config_free(handle->config);
                    handle->config = NULL;
                }
                Safefree(handle);
                SvREADONLY_off(inner);
                sv_setiv(inner, 0);
                SvREADONLY_on(inner);
            }
        }

MODULE = Net::Quiche::XS    PACKAGE = Net::Quiche::XS::Connection

void
DESTROY(object)
        SV *object
    PREINIT:
        SV *inner;
        net_quiche_connection_handle *handle;
    CODE:
        if (SvROK(object)) {
            inner = SvRV(object);
            handle = INT2PTR(net_quiche_connection_handle *, SvIV(inner));
            if (handle != NULL) {
                if (handle->conn != NULL) {
                    quiche_conn_free(handle->conn);
                    handle->conn = NULL;
                }
                Safefree(handle);
                SvREADONLY_off(inner);
                sv_setiv(inner, 0);
                SvREADONLY_on(inner);
            }
        }

MODULE = Net::Quiche::XS    PACKAGE = Net::Quiche::XS::HTTP3

void
DESTROY(object)
        SV *object
    PREINIT:
        SV *inner;
        net_quiche_h3_handle *handle;
    CODE:
        if (SvROK(object)) {
            inner = SvRV(object);
            handle = INT2PTR(net_quiche_h3_handle *, SvIV(inner));
            if (handle != NULL) {
                if (handle->conn != NULL) {
                    quiche_h3_conn_free(handle->conn);
                    handle->conn = NULL;
                }
                Safefree(handle);
                SvREADONLY_off(inner);
                sv_setiv(inner, 0);
                SvREADONLY_on(inner);
            }
        }
