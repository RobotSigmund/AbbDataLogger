# AbbDataLogger

Datalogging using Abb webservices vs an omnicore robot controller.

## Usage

<ins>Generate controller resource tags</ins>

```DataLogger.pl --list_resources```

Will connect to controller, get all IO and PERS programdata URLs. These will be listed in a generated text file, "ServerResources".

<ins>Generate config file</ins>

```DataLogger.pl --reset_config```

Will generate a new DataLogger.ini file. If you connect through the controller sevice port, this should be ok. Otherwise modify to custom IP, user, pass etc.

<ins>Select which resources you want to log</ins>

Copy resource URLs from "ServerResources.txt" to "ListenResources.txt". You will have to create this file.

<ins>Run the datalogger</ins>

```DataLogger.pl --log logdata.log```

Any changes to server resource values will be logged in the terminal. Use optional argument --log to simultaneously write events to a logfile.





