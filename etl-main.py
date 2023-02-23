import datetime
import logging
import os
import sqlite3
import pyodbc


# Set up logging to a file in the same directory as the script
log_file = os.path.join(os.path.dirname(__file__), 'script.log')
logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

# Read the configuration files
last_run_file = os.path.join(os.path.dirname(__file__), 'last_run')
db_config_file = os.path.join(os.path.dirname(__file__), 'db_config')
with open(last_run_file, 'r') as f:
    last_run_timestamp = f.read().strip()
    last_run_datetime = datetime.datetime.fromisoformat(last_run_timestamp)
    with open(db_config_file, 'r') as f:
        connection_string, sqlite_db_path, device_name = f.read().strip().split(',')
        azure_user = os.environ.get('AZURE_DB_USERNAME')
        azure_pass = os.environ.get('AZURE_DB_PASSWORD')
        if azure_user and azure_pass:
            connection_string = connection_string.replace('<uid>', azure_user).replace('<pwd>', azure_pass)
        else:
            logging.error("Environment variables for AZURE DB username or password not set")

        # Connect to the SQLite database
        conn = sqlite3.connect(sqlite_db_path)
        c = conn.cursor()

        # Query the SQLite database for data since the last successful run
        c.execute("""select ? as meta_device,
            datetime() as meta_dateloaded,
            Date,
            Time,
            Sci_Name,
            Com_Name,
            Confidence,
            Lat,
            Lon,
            Cutoff,
            Week,
            Sens,
            Overlap,
            File_Name
        from detections
        WHERE timestamp >= ?""", (device_name,last_run_timestamp,))
        rows = c.fetchall()

        if rows:
            # Connect to the Azure SQL database
            cnxn = pyodbc.connect(connection_string)
            cursor = cnxn.cursor()

            # Insert the data into the Azure SQL database in batches of 200
            try:
                cursor.execute("BEGIN TRANSACTION")
                batch_size = 200
                for i in range(0, len(rows), batch_size):
                    batch = rows[i:i+batch_size]
                    cursor.executemany("""insert into staging.detections (meta_device, meta_dateloaded, Date, Time, Sci_Name, Com_Name, Confidence, Lat, Lon,
                                Cutoff, Week, Sens, Overlap, File_Name) values ( ?,?,?,?,?,?,?,?,?,?,?,?,?,? );""", batch)
                cursor.execute("COMMIT TRANSACTION")
                logging.info("Inserted %d rows into Azure SQL database", len(rows))

                # Update the last successful run timestamp
                new_last_run_datetime = max(row[0] for row in rows)
                with open(last_run_file, 'w') as f:
                    f.write(new_last_run_datetime.isoformat())
                    logging.info("Updated last successful run timestamp to %s", new_last_run_datetime.isoformat())
            except Exception as e:
                cursor.execute("ROLLBACK TRANSACTION")
                logging.error("Failed to insert data into Azure SQL database: %s", str(e))
            finally:
                cursor.close()
                cnxn.close()

        else:
            logging.info("No new data to send to remote server.")
            
        # Close the SQLite database connection
        conn.close()