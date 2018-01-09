package Koha::Plugin::Com::MarywoodUniversity::RoomReservations;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use C4::Context;

our $VERSION = "{VERSION}";

our $metadata = {
    name            => 'Room Reservations Plugin',
    author          => 'Lee Jamison',
    description     => 'This plugin provides a room reservation solution on both intranet and OPAC interfaces.',
    date_authored   => '2017-05-08',
    date_updated    => '1900-01-01',
    minimum_version => '3.22',
    maximum_version => undef,
    version         => $VERSION,
};

## Table names and associated MySQL indexes
#

my $rooms_table = 'booking_rooms';
my $rooms_index = 'bookingrooms_idx';
my $bookings_table = 'bookings';
my $bookings_index = 'bookingbookings_idx';
my $equipment_table = 'booking_equipment';
my $equipment_index = 'bookingequipment_idx';
my $roomequipment_table = 'booking_room_equipment';
my $roomequipment_index = 'bookingroomequipment_idx';

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## NOTE: install() uses an array of double-q commands and
## a for loop of dbh statement execution in order to
## prevent MySQL syntax errors triggered from multiple
## $dbh->do statements

## the first double-q command uses a compound
## DROP TABLE IF EXISTS statement to prevent
## a MySQL syntax error
sub install() {
    my ( $self, $args ) = @_;

    ## TODO: Remove INSERT INTO statements AND remove DROP TABLE IF EXISTS
    ## AND change CREATE TABLE to CREATE TABLE IF NOT EXISTS
    my @installer_statements = (
        qq{DROP TABLE IF EXISTS $bookings_table, $roomequipment_table, $equipment_table, $rooms_table},
        qq{CREATE TABLE $rooms_table (
              `roomid` INT NOT NULL AUTO_INCREMENT,
              `roomnumber` VARCHAR(20) NOT NULL, -- alphanumeric room identifier
              `maxcapacity` INT NOT NULL, -- maximum number of people allowed in the room
            PRIMARY KEY (roomid)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $rooms_index ON $rooms_table(roomid);},
        qq{CREATE TABLE $bookings_table (
              `bookingid` INT NOT NULL AUTO_INCREMENT,
              `borrowernumber` INT NOT NULL, -- foreign key; borrowers table
              `roomid` INT NOT NULL, -- foreign key; $rooms_table table
              `start` DATETIME NOT NULL, -- start date/time of booking
              `end` DATETIME NOT NULL, -- end date/time of booking
              `blackedout` TINYINT(1) NOT NULL DEFAULT 0,
              PRIMARY KEY (bookingid),
              CONSTRAINT calendar_icfk FOREIGN KEY (roomid) REFERENCES $rooms_table(roomid),
              CONSTRAINT calendar_ibfk FOREIGN KEY (borrowernumber) REFERENCES borrowers(borrowernumber)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $bookings_index ON $bookings_table(borrowernumber, roomid);},
        qq{CREATE TABLE $equipment_table (
              `equipmentid` INT NOT NULL AUTO_INCREMENT,
              `equipmentname` VARCHAR(20) NOT NULL,
              PRIMARY KEY (equipmentid)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $equipment_index ON $equipment_table(equipmentid);},
        qq{CREATE TABLE $roomequipment_table (
              `roomid` INT NOT NULL,
              `equipmentid` INT NOT NULL,
              PRIMARY KEY (roomid, equipmentid),
              CONSTRAINT roomequipment_iafk FOREIGN KEY (roomid) REFERENCES $rooms_table(roomid),
              CONSTRAINT roomequipment_ibfk FOREIGN KEY (equipmentid) REFERENCES $equipment_table(equipmentid)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $roomequipment_index ON $roomequipment_table(roomid, equipmentid);},
        qq{INSERT INTO $equipment_table (equipmentname) VALUES ('none');},
    );

    for (@installer_statements) {
        my $sth = C4::Context->dbh->prepare($_);
        $sth->execute or die C4::Context->dbh->errstr;
    }

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    ## The order of this list is intentional
    ## otherwise the DROP commands will fail
    ## due to foreign key constraints
    ## preventing deletion
    ##
    ## NOTE: the order of dropping is the reverse
    ## of the install() method's order

    my @uninstaller_statements = (
        qq{DROP TABLE IF EXISTS $bookings_table;},
        qq{DROP TABLE IF EXISTS $roomequipment_table;},
        qq{DROP TABLE IF EXISTS $equipment_table;},
        qq{DROP TABLE IF EXISTS $rooms_table;},
    );

    for (@uninstaller_statements) {
        my $sth = C4::Context->dbh->prepare($_);
        $sth->execute or die C4::Context->dbh->errstr;
    }

    return 1;
}

## The existance of a 'report' subroutine means the plugin is capable
## of running a report.
## TODO: Add a report option
# sub report {
#     my ( $self, $args ) = @_;
#     my $cgi = $self->{'cgi'};

#     unless ( $cgi->param('output') ) {
#         $self->report_step1();
#     }
#     else {
#         $self->report_step2();
#     }
# }

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};
    my $template = $self->get_template({ file => 'tool.tt' });
    my $op = $cgi->param('op') || q{};
    my $tool_action = $cgi->param('tool_actions_selection');

    # used for manage blackouts
    my $manage_blackouts_submit = $cgi->param('manage-blackouts-submit') || q{}; # delete existing blackout
    my $submit_full_blackout = $cgi->param('submit-full-blackout') || q{}; # add full day blackout(s)
    my $submit_partial_blackout = $cgi->param('submit-partial-blackout') || q{}; # add partial-day blackout

    if ( $op eq 'action-selected' &&  $tool_action eq 'action-manage-reservations') {

        my $bookings = getAllBookings();

        $template->param(
            op => 'manage-reservations',
            bookings => $bookings,
        );
    }
    elsif ( $op eq 'action-selected' && $tool_action eq 'action-manage-blackouts' ) {

    	my $blackouts = getAllBlackedoutBookings();

    	my $rooms = getCurrentRoomNumbers();

    	$template->param(
    		op => 'manage-blackouts',
    		blackouts => $blackouts,
    		current_rooms => $rooms,
    	);
    }
    elsif ( $op eq 'manage-reservations' ) {
        my $selected = $cgi->param('manage-bookings-action');

        my $selectedId = $cgi->param('manage-bookings-id');

        if ( $selected eq 'delete' ) {

            my $deleted = deleteBookingById($selectedId);

            my $bookings = getAllBookings();

            if ($deleted == 0) {
                $template->param(
                    deleted  => 1,
                    bookings => $bookings,
                );
            }
            else {
                $template->param(
                    deleted  => 0,
                    bookings => $bookings,
                );
            }
        }

        $template->param(
            op => $op,
        );
    }
    elsif ( $op eq 'manage-blackouts' &&  $manage_blackouts_submit ne '' ) {

    	# TODO - delete the selected blackout

    	my $bookingid = $cgi->param('manage-blackouts-id');

    	deleteBookingById($bookingid);

    	my $blackouts = getAllBlackedoutBookings();
    	my $rooms = getCurrentRoomNumbers();

    	$template->param(
            op => $op,
            blackouts => $blackouts,
    		current_rooms => $rooms,
        );
    }
    elsif ( $op eq 'manage-blackouts' && $submit_full_blackout ne '' ) {

    	my $blackout_start_date = $cgi->param('blackout-start-date');
    	my $blackout_end_date = $cgi->param('blackout-end-date');
    	my @rooms = $cgi->multi_param('current-room-blackout');

    	my $start_date = sprintf '%3$04d-%02d-%02d', split m:/:, $blackout_start_date;
    	my $end_date = sprintf '%3$04d-%02d-%02d', split m:/:, $blackout_end_date;

    	$start_date = $start_date . ' 00:00:00';
    	$end_date = $end_date . ' 23:59:59';

    	my $current_user = C4::Context->userenv->{'number'};

    	if ( $rooms[0] eq '0' ) {

    		my $room_ids = getAllRoomIds(); # IDs of all rooms in rooms table

    		my @room_IDs = @$room_ids;

    		for my $item ( @room_IDs ) {
    			for my $key ( keys %$item ) {
    				addBlackoutBooking($current_user, $item->{ $key }, $start_date, $end_date);
    			}
    		}
    	}
    	else {

    		for (my $i = 0; $i < scalar(@rooms); $i++) {
    			addBlackoutBooking($current_user, $rooms[$i], $start_date, $end_date);
    		} 
    	}

    	my $blackouts = getAllBlackedoutBookings();
    	my $current_rooms = getCurrentRoomNumbers();

    	$template->param(
            op => $op,
            blackouts => $blackouts,
    		current_rooms => $current_rooms,
        );
    }
    elsif ( $op eq 'manage-blackouts' && $submit_partial_blackout ne '' ) {

    	my $blackout_date = $cgi->param('blackout-date');
    	my $start_time = $cgi->param('blackout-start-time');
    	my $end_time = $cgi->param('blackout-end-time');
    	my @rooms = $cgi->multi_param('current-room-blackout');

    	$blackout_date = sprintf '%3$04d-%02d-%02d', split m:/:, $blackout_date;

    	my $start = $blackout_date . " $start_time";
    	my $end = $blackout_date . " $end_time";

    	my $current_user = C4::Context->userenv->{'number'};

    	if ( $rooms[0] eq '0' ) {

    		my $room_ids = getAllRoomIds(); # IDs of all rooms in rooms table

    		my @room_IDs = @$room_ids;

    		for my $item ( @room_IDs ) {
    			for my $key ( keys %$item ) {
    				addBlackoutBooking($current_user, $item->{ $key }, $start, $end);
    			}
    		}
    	}
    	else {

    		for (my $i = 0; $i < scalar(@rooms); $i++) {
    			addBlackoutBooking($current_user, $rooms[$i], $start, $end);
    		} 
    	}

    	my $blackouts = getAllBlackedoutBookings();
    	my $current_rooms = getCurrentRoomNumbers();

    	$template->param(
            op => $op,
            blackouts => $blackouts,
    		current_rooms => $current_rooms,
        );
    }

    print $cgi->header();
    print $template->output();
}

sub configure {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};
    my $template = $self->get_template({ file => 'configure.tt' });
    my $op = $cgi->param('op') || q{};

    if ( $op eq '' ) { # Displays currently configured rooms


        $template->param(

        );
    }
    elsif ( $op eq 'action-selected' ) {

        my $selected = $cgi->param('config_actions_selection');

        my $action = '';

        if ( $selected eq 'action-select-display' ) {

            $action = 'display-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-add' ) {


            $action = 'add-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-edit' ) {

            $action = 'edit-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-delete' ) {

            $action = 'delete-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-add-equipment' ) {

            $action = 'add-equipment';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-delete-equipment' ) {

            $action = 'delete-equipment';

            $template->param(
                action => $action,
                op => $op,
            );
        }
    }
    elsif ( $op eq 'display-rooms' ) {

        my $roomnumbers = getAllRoomNumbers();

        $template->param(
            op          => $op,
            roomnumbers => $roomnumbers,
        );
    }
    elsif ( $op eq 'display-rooms-detail' ) {

        my $roomIdToDisplay = $cgi->param('selected-displayed-room');

        my $roomDetails = getRoomDetailsById($roomIdToDisplay);

        my $roomEquipment = getRoomEquipmentById($roomIdToDisplay);

        $template->param(
            op => $op,
            selected_room_details => $roomDetails,
            selected_room_equipment => $roomEquipment,
        );
    }
    elsif ( $op eq 'add-rooms' ) {

        my $addedRoom = $cgi->param('added-room') || q{};

        if ($addedRoom eq '1') {
            my $roomnumber = $cgi->param('add-room-roomnumber');
            my $maxcapacity = $cgi->param('add-room-maxcapacity');
            my @selectedEquipment = $cgi->param('selected-equipment');

            ## pass @selectedEquipment by reference
            addRoom($roomnumber, $maxcapacity, \@selectedEquipment);
        }

        my $availableEquipment = getAllRoomEquipmentNamesAndIds();
        my $roomNumbers = getCurrentRoomNumbers();

        $template->param(
            op => $op,
            available_equipment => $availableEquipment,
            all_room_numbers => $roomNumbers,
        );
    }
    elsif ( $op eq 'edit-rooms' ) {

        my $editing = $cgi->param('editing') || q{};
        my $roomDetailsUpdated = $cgi->param('room-details-updated') || q{};
        my $roomEquipmentUpdated = $cgi->param('room-equipment-updated') || q{};

        if ($editing eq '1') {
            my $selectedRoomId = $cgi->param('current-rooms-edit');

            $template->param(
                selected_room_id => $selectedRoomId,
            );
        }

        if ( $roomDetailsUpdated eq '1' ) {
            my $roomIdToUpdate = $cgi->param('room-details-updated-roomid');
            my $updatedRoomNumber = $cgi->param('edit-rooms-room-roomnumber');
            my $updatedMaxCapacity = $cgi->param('edit-rooms-room-maxcapacity');

            updateRoomDetails($roomIdToUpdate, $updatedRoomNumber, $updatedMaxCapacity);
        }

        if ( $roomEquipmentUpdated eq '1' ) {
            my $equipmentRoomId = $cgi->param('room-equipment-updated-roomid');
            my @equipmentIdArray = $cgi->param('edit-rooms-current-equipment');

            updateRoomEquipment($equipmentRoomId, \@equipmentIdArray);
        }

        my $roomNumbers = getAllRoomNumbers();

        $template->param(
            op => $op,
            current_rooms => $roomNumbers,
        );
    }
    elsif ( $op eq 'edit-rooms-selection' ) {

        my $choice = $cgi->param('edit-rooms-choice') || q{};

        my $selectedRoomId = $cgi->param('current-rooms-edit') || q{};

        my $editAction = '';

        if ( $choice eq 'room' ) {

            $editAction = 'edit-rooms-room';
        }

        if ( $choice eq 'equipment' ) {

            $editAction = 'edit-rooms-equipment';
        }

        $template->param(
            op => $op,
            edit_action => $editAction,
            selected_room_id => $selectedRoomId,
        );
    }
    elsif ( $op eq 'edit-rooms-room' ) {

        my $selectedRoomId = $cgi->param('selected-room-id') || q{};

        my $roomDetails = loadRoomDetailsToEditByRoomId($selectedRoomId);

        $template->param(
            op => $op,
            room_details => $roomDetails,
        );
    }
    elsif ( $op eq 'edit-rooms-equipment' ) {

        my $selectedRoomId = $cgi->param('selected-room-id') || q{};

        my $roomDetails = loadRoomDetailsToEditByRoomId($selectedRoomId);

        my $allAvailableEquipment = loadAllEquipment();

        $template->param(
            op => $op,
            room_details => $roomDetails,
            all_available_equipment => $allAvailableEquipment,
        );
    }
    elsif ( $op eq 'delete-rooms' ) {

        my $delete = $cgi->param('delete') || q{};

        if ( $delete eq '1' ) {
            my $roomIdToDelete = $cgi->param('delete-room-radio-button');

            deleteRoom($roomIdToDelete);
        }

        my $availableRooms = getAllRoomNumbersAndIdsAvailableToDelete();

        my $areThereRoomsToDelete = areAnyRoomsAvailableToDelete($availableRooms);

        if ($areThereRoomsToDelete == 1) {
            $template->param(
                rooms_available_to_delete => 1,
            );
        }
        else {
            $template->param(
                rooms_available_to_delete => 0,
            );
        }

        $template->param(
            op => $op,
            available_rooms => $availableRooms,
            rooms_available_to_delete => 1,
        );
    }
    elsif ( $op eq 'add-equipment' ) {

        my $insert = $cgi->param('insert') || q{};

        if ( $insert eq '1') {
            my $addedEquipment = $cgi->param('add-equipment-text-field');

            ## Convert to lowercase to enforce uniformity
            $addedEquipment = lc($addedEquipment);

            ## Enclose in single quotes for DB string compatibility
            $addedEquipment = "'" . $addedEquipment . "'";

            addEquipment($addedEquipment);
        }

        my $availableEquipment = getAllRoomEquipmentNames();

        $template->param(
            op => $op,
            available_equipment => $availableEquipment,
        );
    }
    elsif ( $op eq 'delete-equipment' ) {

        my $delete = $cgi->param('delete') || q{};

        if ( $delete eq '1' ) {
            my $equipmentIdToDelete = $cgi->param('delete-equipment-radio-button');

            deleteEquipment($equipmentIdToDelete);
        }

        my $availableEquipment = getAllRoomEquipmentNamesAndIdsAvailableToDelete();

        $template->param(
            op => $op,
            available_equipment => $availableEquipment,
        );
    }


    print $cgi->header();
    print $template->output();
}

sub getAllBookings {

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        SELECT bk.bookingid, r.roomnumber, b.firstname, b.surname, DATE_FORMAT(bk.start, \"%m/%d/%Y %h:%i %p\") AS start, DATE_FORMAT(bk.end, \"%m/%d/%Y %h:%i %p\") AS end
        FROM borrowers b, $bookings_table bk, $rooms_table r
        WHERE b.borrowernumber = bk.borrowernumber
        AND bk.roomid = r.roomid
        ORDER BY bk.roomid ASC, bk.start DESC;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allBookings;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allBookings, $row );
    }

    return \@allBookings;
}

sub getAllBlackedoutBookings {

	my $dbh = C4::Context->dbh;

	my $sth = '';

	my $query = "
		SELECT bk.bookingid, r.roomnumber, DATE_FORMAT(bk.start, \"%m/%d/%Y %h:%i %p\") AS start, DATE_FORMAT(bk.end, \"%m/%d/%Y %h:%i %p\") AS end
		FROM $bookings_table bk, $rooms_table r
        WHERE bk.roomid = r.roomid
        AND bk.blackedout = 1
        AND bk.start BETWEEN CAST(CONCAT(CURDATE(), \" 00:00:00\") AS DATETIME) AND CAST(CONCAT(DATE_ADD(CURDATE(), INTERVAL 30 DAY), \" 23:59:59\") AS DATETIME)
        ORDER BY bk.start ASC;
	";

	$sth = $dbh->prepare($query);
    $sth->execute();

    my @allBlackedoutBookings;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allBlackedoutBookings, $row );
    }

    return \@allBlackedoutBookings;
}

sub addBlackoutBooking {

    my ( $borrowernumber, $roomid, $start, $end ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("
        INSERT INTO $bookings_table (borrowernumber, roomid, start, end, blackedout) 
        VALUES ($borrowernumber, $roomid, " . "'" . $start . "'" . "," . "'" . $end . "'" . ', 1);');
}

sub deleteBookingById {

    my ( $bookingId ) = @_;

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        DELETE FROM bookings WHERE bookingid = $bookingId;
    ";

    $sth = $dbh->prepare($query);

    my $count = $sth->execute();

    if ($count == 0) { # no row(s) affected
        return 0;
    }
    else { # sucessfully deleted row(s)
        return 1;
    }
}

sub areAnyRoomsAvailableToDelete {

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

sub updateRoomDetails {

    my ( $roomid, $roomnumber, $maxcapacity ) = @_;

    $roomnumber = "'" . $roomnumber . "'";

    ## load access to database
    my $dbh = C4::Context->dbh;

    my $query = "
        UPDATE $rooms_table
        SET roomnumber = $roomnumber, maxcapacity = $maxcapacity
        WHERE roomid = $roomid;";

    $dbh->do($query);
}

sub updateRoomEquipment {

    my ( $roomid, $equipment ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("DELETE FROM $roomequipment_table WHERE roomid = $roomid;");

    foreach my $piece (@$equipment) {

        $dbh->do("INSERT INTO $roomequipment_table (roomid, equipmentid) VALUES ($roomid, $piece);");
    }
}

sub loadRoomDetailsToEditByRoomId {

    my ( $roomid ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT *
        FROM $rooms_table
        WHERE roomid = $roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @roomDetails;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @roomDetails, $row );
    }

    return \@roomDetails;
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

## DO NOT USE - causes strange TT software errors
sub loadRoomEquipmentNamesToEditByRoomId {

    my ( $roomid ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT e.equipmentname
        FROM $equipment_table AS e, $roomequipment_table AS re
        WHERE re.equipmentid = e.equipmentid
        AND re.roomid = $roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @equipmentNames;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @equipmentNames, $row );
    }

    return \@equipmentNames;
}

sub addRoom {

    my ($roomnumber, $maxcapacity, $equipment) = @_;

    ## make $roomnumber SQL-friendly by surrounding with single quotes
    $roomnumber = "'" . $roomnumber . "'";

    my $dbh = C4::Context->dbh;

    ## first insert roomnumber and maxcapacity into $rooms_table
    $dbh->do("INSERT INTO $rooms_table (roomnumber, maxcapacity) VALUES ($roomnumber, $maxcapacity);");

    foreach my $piece (@$equipment) {

        $dbh->do("INSERT INTO $roomequipment_table (roomid, equipmentid) VALUES ((SELECT roomid FROM $rooms_table WHERE roomnumber = $roomnumber), $piece);");
    }
}

sub deleteRoom {

    my ($roomId) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("DELETE FROM $roomequipment_table WHERE roomid = $roomId");

    $dbh->do("DELETE FROM $rooms_table WHERE roomid = $roomId");
}

sub addEquipment {

    my ( $equipmentname ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("INSERT INTO $equipment_table (equipmentname) VALUES ($equipmentname);");
}

sub deleteEquipment {

    my ( $equipmentId ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("DELETE FROM $equipment_table WHERE equipmentid = $equipmentId");
}

sub countRooms {

	## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT COUNT(roomid) AS count
        FROM $rooms_table;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my $row = $sth->fetchrow_hashref();

    my $count = $row->{'count'};

    return $count;
}

sub getAllRoomIds {

	## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomid
        FROM $rooms_table
        ORDER BY roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRoomIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRoomIds, $row );
    }

    return \@allRoomIds;
}

sub getCurrentRoomNumbers {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomid, roomnumber
        FROM $rooms_table
        ORDER BY roomnumber;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRoomNumbers;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRoomNumbers, $row );
    }

    return \@allRoomNumbers;
}

sub getAllRoomEquipmentNames {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT equipmentname
        FROM $equipment_table
        ORDER BY equipmentname;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allEquipmentNames;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allEquipmentNames, $row );
    }

    return \@allEquipmentNames;
}

sub getAllRoomEquipmentNamesAndIds {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT equipmentid, equipmentname
        FROM $equipment_table
        ORDER BY equipmentname;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allEquipmentNamesAndIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allEquipmentNamesAndIds, $row );
    }

    return \@allEquipmentNamesAndIds;
}

sub getAllRoomEquipmentNamesAndIdsAvailableToDelete {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT equipmentid, equipmentname
        FROM $equipment_table
        WHERE equipmentid NOT IN
            (SELECT equipmentid FROM $roomequipment_table)
        ORDER BY equipmentname;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allEquipmentNamesAndIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allEquipmentNamesAndIds, $row );
    }

    return \@allEquipmentNamesAndIds;
}

sub getAllRoomNumbersAndIdsAvailableToDelete {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomid, roomnumber
        FROM $rooms_table
        WHERE roomid NOT IN
            (SELECT roomid FROM $bookings_table)
        ORDER BY roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRoomNumbersAndIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRoomNumbersAndIds, $row );
    }

    return \@allRoomNumbersAndIds;
}

sub getRoomDetailsById {

    my ( $selectedRoomId ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    ## Note: GROUP BY is used to prevent duplication of rows in next step
    my $query = "
        SELECT r.roomnumber, r.maxcapacity, e.equipmentname
        FROM $rooms_table AS r, $equipment_table AS e, $roomequipment_table AS re
        WHERE r.roomid = re.roomid
        AND   e.equipmentid = re.equipmentid
        AND r.roomid = $selectedRoomId
        GROUP BY r.roomnumber;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @selectedRoomDetails;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @selectedRoomDetails, $row );
    }

    return \@selectedRoomDetails;
}

sub getRoomEquipmentById {

    my ( $selectedRoomId ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT e.equipmentname
        FROM $equipment_table AS e, $roomequipment_table AS re
        WHERE e.equipmentid = re.equipmentid
        AND re.roomid = $selectedRoomId;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @selectedRoomEquipment;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @selectedRoomEquipment, $row );
    }

    return \@selectedRoomEquipment;
}

## Used in display-rooms
## Returns an array
## Key: roomnumber
## Value: maxcapacity
sub getAllRoomNumbers {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = '';

    ## room selection query
    $query = "SELECT * FROM $rooms_table;";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRooms;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRooms, $row );
    }

    return \@allRooms;

    # my @allRooms;

    # while ( my $roomno = $sth->fetchrow_hashref ) {
    #     push (@allRooms, $roomno);
    # }

    # return \@allRooms;
}

## Used in display-rooms
## param: an arrayref
## return: multi-dimensional hashref
sub displayAllRooms {

    my ($listOfRooms) = @_;

    my $dbh = C4::Context->dbh;

    my $sth = "";

    my $roomnumber = "";

    my $query = "";

    my $featurecount = 0;

    # will be used as hashref (hash of hashes)
    my %roomsAndFeatures;

    foreach my $room ( keys %{ $listOfRooms } ) {

        $roomnumber = "'" . $room . "'";

        #$query = "SELECT $rooms_table.roomnumber, $rooms_table.maxcapacity, $features_table.featurename from $rooms_table, $features_table WHERE featureid IN
        #    (SELECT featureid FROM $configs_table WHERE roomid = 
        #        (SELECT roomid FROM $rooms_table WHERE roomnumber = $roomnumber)) AND $rooms_table.roomnumber = $roomnumber;";

        $sth = $dbh->prepare($query);
        $sth->execute();

        while ( my $features = $sth->fetchrow_arrayref() ) {
                            ##   roomnumber         featurename
            $roomsAndFeatures{ $features->[0] } = $features->[1];
        }
    }

    # returns hashref for performance boost
    return \%roomsAndFeatures;
}

1;