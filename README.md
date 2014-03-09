mysqlbackupper
==============

A Bash script that makes a backup of your MySQL instance without any interuption
to the MySQL process.
This script is build around Percona's Xtrabackup.

It makes an NFS connection to another server to have the backups stored on a
different computer, ensuring the backups are still there when something goes
horribly wrong with the original server.
It then uses xtrabackup to make the actual backup. xtrabackup only makes
backups of InnoDB tables, but this script has some extra scripting added to
also backup tables with different storage engines (like MyISAM).

It creates a logfile to check what happened in the last run. It also creates an
configurable amount of backups, so you can go back into time to an older backup.
Offcourse it supports incremental backups, so you don't have to backup
everything every time.

IMPORTANT NOTE: this script is still in development. Not all the features
already work as advertised or could be impproved opon.
