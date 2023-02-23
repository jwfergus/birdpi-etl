#!/bin/bash

#TODO
#   Connect all function parameters

SQLITE_DB_PATH = "/home/BirdNET-Pi/scripts/birds.db"
#Gets needed prompts from user:
#   BIRDPI_PASSWORD1    - password for etl user we're creating
#   DEVICE_NAME         - device name that will be recorded in database when reporting bird detections
#   AZURE_DB_SERVER     - Azure SQL DB servername
#   AZURE_DB_NAME       - Azure SQL DB name
#   AZURE_DB_USERNAME   - Azure SQL DB username for ETL
#   AZURE_DB_PASSWORD1  - Azure SQL DB password
prompt_user

create_user_account "$BIRDPI_PASSWORD1"

install_python_requirements

create_config_files "$AZURE_DB_SERVER" "$AZURE_DB_NAME" "$SQLITE_DB_PATH" "$DEVICE_NAME" 



# Prompt the user for inputs
function prompt_user() {
    read -p "Enter the device name (default is hostname): " DEVICE_NAME
    DEVICE_NAME=${DEVICE_NAME:-$(hostname)}

    read -s -p "This ETL will run under a new user account (birdpi-etl). Enter the desired password for this account: " BIRDPI_PASSWORD1
    echo

    read -s -p "Confirm the password: " BIRDPI_PASSWORD2
    echo

    while [[ "$BIRDPI_PASSWORD1" != "$BIRDPI_PASSWORD2" ]]; do
        echo "Passwords do not match. Please try again."
        read -s -p "Enter the desired password for this account: " BIRDPI_PASSWORD1
        echo

        read -s -p "Confirm the password: " BIRDPI_PASSWORD2
        echo
    done

    read -p "Enter the Azure SQL DB servername (for example: testserver.database.windows.net): " AZURE_DB_SERVER

    read -p "Enter the Azure SQL DB database name (for example: BirdDetections): " AZURE_DB_NAME

    read -p "Enter the Azure SQL DB username: " AZURE_DB_USERNAME

    read -s -p "Enter the Azure SQL DB password: " AZURE_DB_PASSWORD1
    echo

    read -s -p "Confirm the password: " AZURE_DB_PASSWORD2
    echo

    while [[ "$AZURE_DB_PASSWORD1" != "$AZURE_DB_PASSWORD2" ]]; do
        echo "Passwords do not match. Please try again."
        read -s -p "Enter the Azure SQL DB password: " AZURE_DB_PASSWORD1
        echo

        read -s -p "Confirm the password: " AZURE_DB_PASSWORD2
        echo
    done
}

function create_user_account() {
    # Set up variables
    USERNAME="birdpi-etl"  # Change this to the desired username
    PASSWORD="$1"  # Change this to the desired password

    # Create the new user
    sudo useradd -m -s /bin/bash $USERNAME

    # Set the user's password
    echo "$USERNAME:$PASSWORD" | sudo chpasswd

    # Set environment variables for the specific user
    sudo -u $USERNAME bash -c "echo 'export AZURE_DB_USERNAME=$1' >> ~/.bashrc"
    sudo -u $USERNAME bash -c "echo 'export AZURE_DB_PASSWORD=$PASSWORD' >> ~/.bashrc"


    # Set up local login only
    sudo echo "Match User $USERNAME" >> /etc/ssh/sshd_config
    sudo echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    sudo echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config
    sudo echo "X11Forwarding no" >> /etc/ssh/sshd_config
    sudo echo "AllowAgentForwarding no" >> /etc/ssh/sshd_config

    # Restart SSH service
    sudo systemctl restart sshd.service

    # Give the new user permission to read the database file
    sudo setfacl -m u:$USERNAME:r $SQLITE_DB_PATH

}

function install_python_requirements() {
    # Do something with the Azure DB credentials
    BIRDPI_ETL_HOME=$(getent passwd birdpi-etl | cut -d: -f6)

    mkdir "$BIRDPI_ETL_HOME/etl"
    cd "$BIRDPI_ETL_HOME/etl"

    # Install required Python modules
    pip install pyodbc

    # Import the public repository GPG keys
    curl https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -

    # Register the Microsoft SQL Server Ubuntu repository
    curl https://packages.microsoft.com/config/debian/10/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list

    # Update the package list and install the ODBC driver and its dependencies
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get -yq install msodbcsql18 unixodbc-dev

    # Configure ODBC driver
    sudo su << EOF
    cat << EOT > /etc/odbcinst.ini
    [ODBC Driver 18 for SQL Server]
    Description=Microsoft ODBC Driver 18 for SQL Server
    Driver=/opt/microsoft/msodbcsql18/lib64/libmsodbcsql-18.4.so.2.0
    UsageCount=1
    EOT
    EOF
}

function fetch_main_python_file(){
    curl https://packages.microsoft.com/keys/microsoft.asc 
}

function create_config_files() {


    # Create the configuration files
    cat << EOF > last_run
    2022-01-01T00:00:00.000000
    EOF

    cat << EOF > db_config
    Driver={ODBC Driver 18 for SQL Server};Server=tcp:$1,1433;Database=$2;Uid=<uid>;Pwd=<pwd>;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;,$3,$4

    EOF

    # Make the Python script executable
    chmod +x etl-main.py

    # Set up a cron job to run the Python script every 15 minutes
    echo "*/15 * * * * cd $(pwd) && ./etl-main.py >> script.log 2>&1" | crontab -

    # Confirm that the cron job was set up correctly
    crontab -l
}

