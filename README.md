### Migrate database in container
Script to migrate a database from one container to another on the same host - Still a work in progress

Pull both the Run_Migration_v2.ps1 and docker.exe file into the same location.

Usage ./Run_Migration_v2.ps1

The following parameters will be asked for: -

$dockerhost     - IP address of the docker host 
<br>
$source         - Name of the source container
<br>
$dest           - Name of the destination container
<br>
$database       - Name of the database to be migrated

You will also be prompted to enter in details in order to connect to the SQL instance in both containers. This script assumes that the login details used are the same for both containers.
