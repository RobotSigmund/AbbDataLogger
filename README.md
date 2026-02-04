# AbbDataLogger

Datalogging using Abb webservices vs an omnicore robot controller. Note, this is a quick and dirty, not general purpose, but very functional datalogger. Pull resources from controller, choose what you want to watch, run the datalogger and it will store timestamped events where selected data changes value. Very useful for debugging where internal logging is not available.

Standard Perl modules are used for all network activity, also XHTML parson is done by standard modules. This ensures pretty safe datahandling.


## Usage

<ins>Generate config file</ins>

```DataLogger.pl --reset_config```

Will generate a new DataLogger.ini file. If you connect through the controller sevice port, this should be ok. Otherwise modify to custom IP, user, pass etc.

<img width="1113" height="123" alt="image" src="https://github.com/user-attachments/assets/a2866ab0-fbcf-4013-bfde-85198f12bf66" />


*DataLogger.ini*:  
```[connection]
https=1
password=robotics
server_ip=192.168.125.1
server_port=443
username=Default User

[files]
file_listen_resources=ListenResources.txt
file_server_resources=ServerResources.txt
```

<ins>Generate controller resource tags</ins>

```DataLogger.pl --list_resources```

Will connect to controller, get all IO and PERS programdata URLs. These will be listed in a generated text file, "ServerResources".

<img width="1113" height="161" alt="image" src="https://github.com/user-attachments/assets/6bbdb002-8df9-46a3-80e5-07a2f067223f" />

<ins>Select which resources you want to log</ins>

Copy resource URLs from "ServerResources.txt" to "ListenResources.txt". You will have to create this file.

<img width="1171" height="365" alt="image" src="https://github.com/user-attachments/assets/f20d1448-b333-4aa6-846a-ddacdeb763b5" />

<ins>Run the datalogger</ins>

```DataLogger.pl```

Any changes to server resource values will be logged in the terminal. Use optional argument --log to simultaneously write events to a logfile.

<img width="1113" height="512" alt="image" src="https://github.com/user-attachments/assets/34c90b8a-4e3f-4b08-94e4-4a9ab043d7ff" />

**Optional arguments**

```--short_naming```

Each update will show only the Pers-programdata name or the IO name. Not the whole resource path.

```--log <filename>```

Will verbose both to the console window and a logfile.




