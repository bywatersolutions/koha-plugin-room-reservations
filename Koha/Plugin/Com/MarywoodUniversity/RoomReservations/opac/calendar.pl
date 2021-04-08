#!/usr/bin/perl
#
# Copyright 2017 Marywood University
#
# This file is not part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.
use Modern::Perl;

use Carp;
use C4::Context;
use C4::Output;
use C4::Auth;
use Koha::Email;
use Mail::Sendmail;
use MIME::QuotedPrint;
use MIME::Base64;
use Koha::Patrons;
use Koha::Patron::Category;
use Koha::Patron::Categories;
use Koha::DateUtils;
use Cwd            qw( abs_path );
use File::Basename qw( dirname );
use POSIX 'strftime';
use POSIX 'floor';

use CGI qw ( -utf8 );

use Locale::Messages;
Locale::Messages->select_package('gettext_pp');

use Locale::Messages qw(:locale_h :libintl_h);

use Calendar::Simple;
my @months = (gettext('January'), gettext('February'), gettext('March'), gettext('April'), gettext('May'), gettext('June'), gettext('July'), gettext('August'), gettext('September'), gettext('October'), gettext('November'), gettext('December'));

my $pluginDir = dirname(abs_path($0));

my $template_name = $pluginDir . '/calendar.tt';
my $template2_name = $pluginDir . '/calendar-sendconfirmation.tt';

my $rooms_table = 'booking_rooms';
my $bookings_table = 'bookings';
my $equipment_table = 'booking_equipment';
my $roomequipment_table = 'booking_room_equipment';

my $valid; # used to check if booking still valid prior to insertion of new booking

my $cgi = new CGI;

# initial value -- calendar is displayed while $op is undef
# otherwise one of the form pages is displayed
my $op = $cgi->param('op');

my ( $template, $borrowernumber, $cookie ) = get_template_and_user(
    {
        template_name   => $template_name,
        query           => $cgi,
        type            => "opac",
        authnotrequired => 0,
        is_plugin       => 1,
    }
);

$template->param(
    language => C4::Languages::getlanguage($cgi) || 'en',
    mbf_path => abs_path( '../translations' )
);

if ( !defined($op) ) {
	my $selected_mon_cnt = $cgi->param('selected_mon_cnt');
	
	my $mon = (localtime)[4] + 1;
    my $yr  = (localtime)[5] + 1900;

	if ( defined($selected_mon_cnt) ) {
		$yr  = $yr + floor(($mon + $selected_mon_cnt - 1) / 12);
		$mon = ($mon + $selected_mon_cnt) % 12;
	}

    my @month = calendar($mon, $yr);
    my @month_days;

    foreach(@month) {
        push(@month_days, map { $_ ? sprintf "%d", $_ : '' } @$_);
    }

    my $calendarBookings = getConfirmedCalendarBookingsByMonthAndYear($mon, $yr);

    my $month = sprintf("%02s", $mon);

    my $userenv = C4::Context->userenv;
    my $number = $userenv->{number};
    my $patron = Koha::Patrons->find($number);
    my $category = $patron->category->categorycode;

    my $isRestricted = checkForRestrictedCategory($category);

    my $restricted_message = getRestrictedMessage();

    if ($isRestricted > 0) {
        $template->param(
            is_restricted => 1,
            is_restricted_message => $restricted_message,
            patron_category => $category,
        );
    }
    else {
        $template->param(
            is_restricted => undef,
            patron_category => $category,
        );
    }

    $template->param(
        current_month_cal => \@month_days,
        calendar_bookings => $calendarBookings,
        active_month      => $months[$mon - 1],
        active_year       => $yr + 0,
        month_is_active   => 1,
        plugin_dir        => $pluginDir,
        op                => $op,
        selected_mon_cnt  => $selected_mon_cnt,
    );
}
elsif ( $op eq 'availability-search' ) {

    my $equipment = loadAllEquipment();

    my $capacities = loadAllMaxCapacities();

    my $max_num_days = getFutureDays() || '0';

    my $max_time = getMaxTime() || '0';

    if ( $max_num_days eq '0' ) {
        $max_num_days = '';
    }

    if ( $max_time eq '0' ) {
        $max_time = '';
    }

    $template->param(
        op => $op,
        available_room_equipment => $equipment,
        all_room_capacities => $capacities,
        max_days => $max_num_days,
        max_time => $max_time,
    );
}
elsif ( $op eq 'availability-search-results' ) {

    my $start_date = $cgi->param('availability-search-start-date');
    my $start_time = $cgi->param('availability-search-start-time');

    my $end_date = $cgi->param('availability-search-end-date');
    my $end_time = $cgi->param('availability-search-end-time');

    my $room_capacity = $cgi->param('availability-search-room-capacity');

    my @equipment = $cgi->param('availability-search-selected-equipment') || ();

    my $event_start = sprintf("%s %s", $start_date, $start_time);
    my $event_end   = sprintf("%s %s", $end_date, $end_time);

    # converts '/' to '-'
    (my $availability_format_start_date = $start_date) =~ s/\//\-/g;
    (my $availability_format_end_date = $end_date) =~ s/\//\-/g;

    # re-arranges from MM-DD-YYYY to YYYY-MM-DD
    ($availability_format_start_date = $availability_format_start_date) =~ s/(\d\d)-(\d\d)-(\d\d\d\d)/$3-$1-$2/;
    ($availability_format_end_date = $availability_format_end_date) =~ s/(\d\d)-(\d\d)-(\d\d\d\d)/$3-$1-$2/;

    # used exclusively for getAvailableRooms -- BUG excluding T from the DATETIME start/end field returns wrong results?
    my $availability_format_start = sprintf("%sT%s", $availability_format_start_date, $start_time);
    my $availability_format_end   = sprintf("%sT%s", $availability_format_end_date, $end_time);

    # generates a DateTime object from a string
    $event_start = dt_from_string($event_start);
    $event_end = dt_from_string($event_end);

    my $displayed_event_start = output_pref({ dt => $event_start, }); # dateformat => 'us', timeformat => '12hr' });
    my $displayed_event_end = output_pref({ dt => $event_end, }); #dateformat => 'us', timeformat => '12hr' });

    my $availableRooms = getAvailableRooms($availability_format_start, $availability_format_end, $room_capacity, \@equipment);

    # boolean -- returns 1 (one) if true or 0 (zero) if false
    my $roomsAreAvailable = areAnyRoomsAvailable($availableRooms);

    $template->param(
        op => $op,
        available_rooms => $availableRooms,
        are_rooms_available => $roomsAreAvailable,
        displayed_start => $displayed_event_start,
        displayed_end => $displayed_event_end,
        event_start_time => $event_start,
        event_end_time => $event_end,
        start_date => $availability_format_start_date,
    );
}
elsif ( $op eq 'room-selection-confirmation' ) {

    my $selected_id = $cgi->param('selected-room-id');
    my $displayed_start = $cgi->param('displayed-start');
    my $displayed_end = $cgi->param('displayed-end');
    my $event_start = $cgi->param('event-start-time');
    my $event_end = $cgi->param('event-end-time');

    my $start_date = $cgi->param('start-date');

    my $displayed_event_time = "$displayed_start - $displayed_end";

    my $user_fn = C4::Context->userenv->{'firstname'} || q{};
    my $user_ln = C4::Context->userenv->{'surname'} || q{};
    my $user_bn = C4::Context->userenv->{'number'};

    my $user = "$user_fn $user_ln";
    my $email = C4::Context->userenv->{'emailaddress'};

    my $selectedRoomNumber = getRoomNumberById($selected_id);

    my $count_limit = getDailyReservationLimit();

    my $current_user_daily_limit = getUserDailyResLimit($user_bn, $start_date);

    $template->param(
        op                  => $op,
        current_user        => $user,
        current_user_fn     => $user_fn,
        current_user_ln     => $user_ln,
        current_user_email  => $email,
        selected_room_id    => $selected_id,
        selected_room_no    => $selectedRoomNumber,
        displayed_time      => $displayed_event_time,
        selected_start_time => $event_start,
        selected_end_time   => $event_end,
        displayed_start     => $displayed_start,
        displayed_end       => $displayed_end,
        count_limit         => $count_limit,
        user_daily_limit    => $current_user_daily_limit,
    );
}
elsif( $op eq 'reservation-confirmed' ) {

    my $borrowernumber = C4::Context->userenv->{'number'};
    my $roomid = $cgi->param('confirmed-room-id');
    my $start   = $cgi->param('confirmed-start');
    my $end     = $cgi->param('confirmed-end');
    my $sendCopy = $cgi->param('send-confirmation-copy') || q{};
    my $submitButton = $cgi->param('confirmationSubmit');
    my $user = $cgi->param('confirmed-user');
    my $roomnumber = $cgi->param('confirmed-roomnumber');
    my $displayed_start = $cgi->param('confirmed-displayed-start');
    my $displayed_end = $cgi->param('confirmed-displayed-end');
    my $patronEmail = $cgi->param('confirmed-email');

    if ( $submitButton eq 'Start over' ) {

        $op = 'availability-search';
    }
    else {

        $valid = preBookingAvailabilityCheck($roomid, $start, $end);

        if ($valid) {
            addBooking($borrowernumber, $roomid, $start, $end);
        }
        else {
            $template->param(
                invalid_booking => 1,
            );
        }
    }

    if ( $sendCopy eq '1' && $valid ) {

        my $email = Koha::Email->new();
        my $user_email = C4::Context->preference('KohaAdminEmailAddress');

        # KohaAdmin address is the default - no need to set
        my %mail = $email->create_message_headers({
            to => $patronEmail,
        });
        $mail{'X-Abuse-Report'} = C4::Context->preference('KohaAdminEmailAddress');

        # Since we are already logged in, no need to check credentials again
        # when loading a second template.
        my $template2 = C4::Templates::gettemplate(
            $template2_name, 'opac', $cgi, 1
        );

        my $timestamp = getCurrentTimestamp();

        $template2->param(
            user => $user,
            room => $roomnumber,
            from => $displayed_start,
            to   => $displayed_end,
            confirmed_timestamp => $timestamp,
        );

        # Getting template result
        my $template_res = $template2->output();
        my $body;

        # Analysing information and getting mail properties

        if ($template_res =~ /<SUBJECT>(.*)<END_SUBJECT>/s) {
            $mail{subject} = $1;
            $mail{subject} =~ s|\n?(.*)\n?|$1|;
            $mail{subject} = Encode::encode("UTF-8", $mail{subject});
        }
        else { $mail{'subject'} = "no subject"; }

        my $email_header = "";

        if ( $template_res =~ /<HEADER>(.*)<END_HEADER>/s ) {
            $email_header = $1;
            $email_header =~ s|\n?(.*)\n?|$1|;
            $email_header = encode_qp(Encode::encode("UTF-8", $email_header));
        }

        my $email_file = "bookingconfirmation.txt";
        if ( $template_res =~ /<FILENAME>(.*)<END_FILENAME>/s ) {
            $email_file = $1;
            $email_file =~ s|\n?(.*)\n?|$1|;
        }

        if ( $template_res =~ /<MESSAGE>(.*)<END_MESSAGE>/s ) {
            $body = $1;
            $body =~ s|\n?(.*)\n?|$1|;
            $body = encode_qp(Encode::encode("UTF-8", $body));
        }

        $mail{body} = $body;

        my $boundary = "====" . time() . "====";

        $mail{'content-type'} = "multipart/mixed; boundary=\"$boundary\"";
        $boundary = '--' . $boundary;
        $mail{body} = <<END_OF_BODY;
$boundary
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable
$email_header
$body
$boundary--
END_OF_BODY

## This version includes file attachment (if necessary)
# $boundary
# MIME-Version: 1.0
# Content-Type: text/plain; charset="UTF-8"
# Content-Transfer-Encoding: quoted-printable
# $email_header
# $body
# $boundary
# Content-Type: application/octet-stream; name="basket.iso2709"
# Content-Transfer-Encoding: base64
# Content-Disposition: attachment; filename="basket.iso2709"
# $isofile
# $boundary--
# END_OF_BODY

        # Sending mail (if not empty basket)
        if (sendmail %mail) {
            # do something if it works....
            $template->param(
                SENT      => "1",
                patron_email => $patronEmail,
            );
        }
        else {
            # do something if it doesnt work....
            carp "Error sending mail: an error has occurred";
            carp "Error sending mail: $Mail::Sendmail::error" if $Mail::Sendmail::error;
            $template->param( error => 1 );
        }
    }

    $template->param(
        op => $op,
    );
}

sub checkForRestrictedCategory {

    my ( $category ) = @_;

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        SELECT COUNT(categorycode)
        FROM categories, plugin_data
        WHERE plugin_class = 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations'
        AND plugin_key LIKE 'rcat_%'
        AND plugin_value = categorycode
        AND plugin_value = ?;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute($category);

    my $rows = $sth->fetchrow_arrayref->[0];

    if ( $rows != 0 ) {
        return 1; # restricted
    }
    else {
        return 0; # not restricted
    }
}

sub getRestrictedMessage {

    my $dbh = C4::Context->dbh;
    my $sql = "SELECT plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute( 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations', 'restricted_message' );
    my $row = $sth->fetchrow_hashref();

    return $row->{'plugin_value'};
}

sub getFutureDays {

    my $dbh = C4::Context->dbh;
    my $sql = "SELECT plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute( 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations', 'max_future_days' );
    my $row = $sth->fetchrow_hashref();

    return $row->{'plugin_value'};
}

sub getMaxTime {

    my $dbh = C4::Context->dbh;
    my $sql = "SELECT plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute( 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations', 'max_time' );
    my $row = $sth->fetchrow_hashref();

    return $row->{'plugin_value'};
}

sub getDailyReservationLimit {

    my $dbh = C4::Context->dbh;
    my $sql = "SELECT plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute( 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations', 'count_limit' );
    my $row = $sth->fetchrow_hashref();

    return $row->{'plugin_value'};
}

sub getUserDailyResLimit {

    my ($bn, $date) = @_;

    $date = "$date%";

    my $dbh = C4::Context->dbh;
    my $sql = "SELECT COUNT(*) AS daily_total FROM bookings WHERE borrowernumber = ? AND start LIKE ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute( $bn, $date );
    my $row = $sth->fetchrow_hashref();

    return $row->{'daily_total'};
}

sub areAnyRoomsAvailable {

    my ( $rooms ) = @_;

    if ( @$rooms > 0 ) {
        # return true
        return 1;
    }
    else {
        # return false
        return 0;
    }
}

sub getConfirmedCalendarBookingsByMonthAndYear {

    my ($month, $year) = @_;

    ## zero-pad the month to be DATETIME-friendly (two-digit)
    $month = sprintf("%02s", $month);

    # load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    ## Returns hashref of the fields:
    ## roomnumber, monthdate, bookedtime
    my $query =
    'SELECT
        r.roomnumber,
        DATE_FORMAT(b.start, "%e") AS monthdate,
        CONCAT(DATE_FORMAT(b.start, "%H:%i"), " - ", DATE_FORMAT(b.end, "%H:%i")) AS bookedtime
        FROM ' . "$rooms_table AS r, $bookings_table AS b " .
        'WHERE r.roomid = b.roomid
        AND start BETWEEN \'' . "$year-$month-01 00:00:00' AND '" . "$year-$month-31 23:59:59'" .
        'ORDER BY b.roomid ASC, start ASC';

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @calendarBookings;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @calendarBookings, $row );
    }

    return \@calendarBookings;
}

sub preBookingAvailabilityCheck {
    my ( $roomid, $start, $end ) = @_;

    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT COUNT(*)
        FROM $bookings_table
        WHERE roomid = $roomid
        AND \'$end\' > start
        AND \'$start\' < end;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my ($count) = $sth->fetchrow_array();

    if ($count > 0) { # a conflicting booking was found
        return 0;
    }
    else { # no conflict found
        return 1;
    }
}

sub addBooking {

    my ( $borrowernumber, $roomid, $start, $end ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("
        INSERT INTO $bookings_table (borrowernumber, roomid, start, end)
        VALUES ($borrowernumber, $roomid, " . "'" . $start . "'" . "," . "'" . $end . "'" . ');');
}

sub getRoomNumberById {

    my ( $roomid ) = @_;

    # load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomnumber
        FROM $rooms_table
        WHERE roomid = $roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @roomNumberFromId;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @roomNumberFromId, $row );
    }

    return \@roomNumberFromId;
}

sub getAvailableRooms {

    my ( $start, $end, $capacity, $equipment ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT *
        FROM $rooms_table
        WHERE maxcapacity = $capacity
        AND roomid NOT IN
            (SELECT roomid
            FROM $bookings_table
            WHERE
            \'$end\' > start AND \'$start\' < end)";

        # if dereferenced array ref has zero elements (length evaluated in scalar context)
        if ( @$equipment > 0 ) {

            # counts number of elements
            my $totalElements = scalar @{ $equipment };

            $query .= " AND roomid IN (SELECT roomid
                                        FROM $roomequipment_table
                                        WHERE";

            foreach my $piece (@$equipment) {

                if ( --$totalElements == 0 ) {

                    $query .= " equipmentid = $piece)";
                }
                else {
                    $query .= " equipmentid = $piece AND";
                }

                $totalElements--;
            }
        }

        $query .= ' GROUP BY roomnumber;';

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allAvailableRooms;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allAvailableRooms, $row );
    }

    return \@allAvailableRooms;
}

sub loadAllMaxCapacities {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT DISTINCT maxcapacity
        FROM $rooms_table;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allMaxCapacities;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allMaxCapacities, $row );
    }

    return \@allMaxCapacities;
}

sub loadAllEquipment {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT *
        FROM $equipment_table;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allAvailableEquipmentNames;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allAvailableEquipmentNames, $row );
    }

    return \@allAvailableEquipmentNames;
}

sub getCurrentTimestamp {

    my $timestamp = strftime('%m/%d/%Y %I:%M:%S %p', localtime);

    return $timestamp;
}

output_html_with_http_headers $cgi, $cookie, $template->output;
