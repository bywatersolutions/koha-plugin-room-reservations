# Introduction

Koha's Plugin System (available in Koha 3.12+) allows for you to add additional tools and reports to [Koha](http://koha-community.org) that are specific to your library. Plugins are installed by uploading KPZ ( Koha Plugin Zip ) packages. A KPZ file is just a zip file containing the perl files, template files, and any other files necessary to make the plugin work. Learn more about the Koha Plugin System in the [Koha 3.22 Manual](http://manual.koha-community.org/3.22/en/pluginsystem.html) or watch [Kyle's tutorial video](http://bywatersolutions.com/2013/01/23/koha-plugin-system-coming-soon/).

# Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-kitchen-sink/releases) you can download the relevant *.kpz file

# Installing

Koha's Plugin System allows for you to add additional tools and reports to Koha that are specific to your library. Plugins are installed by uploading KPZ ( Koha Plugin Zip ) packages. A KPZ file is just a zip file containing the perl files, template files, and any other files necessary to make the plugin work.

The plugin system needs to be turned on by a system administrator.

To set up the Koha plugin system you must first make some changes to your install.

* Change `<enable_plugins>0<enable_plugins>` to `<enable_plugins>1</enable_plugins>` in your koha-conf.xml file
* Confirm that the path to `<pluginsdir>` exists, is correct, and is writable by the web server
* Restart your webserver

Once set up is complete you will need to alter your UseKohaPlugins system preference. On the Tools page you will see the Tools Plugins and on the Reports page you will see the Reports Plugins.

# Package from source

From the root of the room reservation git folder, make sure `zip` is installed and package the plugin with the command

    zip -r package-file-name.kpz Koha/

The `-r` flag compresses everything contained within the Koha folder into a file with the specified name. The important part about the file name is for it to end with `.kpz`.

# Apache Configuration

* These instructions assume the plugin is being installed in [kohadevbox](https://github.com/digibib/kohadevbox). If installing for production change the file paths accordingly.

In order for the Room Reservations plugin to work from the OPAC, Apache needs to be tweaked.

First, add the following ScriptAlias Directive to your Apache configuration file under the OPAC section (on Debian, depending on your installation, the configuration file is typically located in `/etc/apache2/sites-enabled`)

    ScriptAlias /booking "/var/lib/koha/kohadev/plugins/Koha/Plugin/Com/MarywoodUniversity/RoomReservations/opac/calendar.pl"

Next, also under the OPAC section of the koha.conf Apache configuration file, we need to add an Alias entry so the plugins folder can be reached from the OPAC

    Alias /plugin "/var/lib/koha/kohadev/plugins"

Last, we need to add a directive to `/etc/apache2/apache2.conf` to prevent 403 errors on the OPAC
    
**Important**
The following directory stanza is only required in **Apache 2.4+**. `Require all granted` will result in breaks on **Apache 2.2 and below**.
    
    <Directory /var/lib/koha/kohadev/plugins/>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

# File Configuration

After installing the plugin, do the following for proper file permissions to prevent 500 errors:

Run

    sudo chmod a+x calendar.pl

from within the RoomReservations folder

# Prerequisite Modules

This plugin requires the following modules to be installed:

    Cwd
    File::Basename
    Calendar::Simple

# Add link to OPAC

To add a link to this plugin for acess from the OPAC add the following lines to the `OPACUserJs` System Preference

    /* Add Booking link for redirection plugin script */
    $("#moresearches li:contains('Advanced search')").after("<li><a href='/booking' target='_blank'>Booking</a></li>");