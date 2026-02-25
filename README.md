# AbbDataLogger

Datalogging using Abb webservices vs an omnicore robot controller. Note, this is a quick and dirty, not general purpose, but very functional datalogger. Pull resources from controller, choose what you want to watch, run the datalogger and it will store timestamped events where selected data changes value. Very useful for debugging where internal logging is not available.

Standard Perl modules are used for all network activity and XHTML data parsing. This ensures pretty safe datahandling.


## Usage

<ins>Generate config file</ins>

```DataLogger.pl --reset_config```

Will generate a new DataLogger.ini file. If you connect through the controller service port, the generated configuration file will work without modifications. Otherwise modify to custom IP, username and password etc.

<img width="1113" height="123" alt="image" src="https://github.com/user-attachments/assets/a2866ab0-fbcf-4013-bfde-85198f12bf66" />


*DataLogger.ini*:  
```
[connection]
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


## Troubleshooting

### Windows

Install strawberryperl; [strawberryperl.com](https://strawberryperl.com/).


### Missing modules

Open the perlfile in a text editor. All necessary modules are listet at the beginnning of the file. Example: *use Foo::Bar;*


#### Linux

Open terminal. Install using cpan.

```cpan install Foo::Bar```


#### Windows

Go to strawberryperl in the start menu. Run cpan client.

```install Foo::Bar```


## Virtual controllers

Typicly listens on port 80. If this is allready reserved it will try several standard ports (80, 5466, 9403, 9805, 11622, 19985, 31015, 34250, 40129, 45003). If none are available a random port will be picked.

Find the active port in an elevated console.

```tasklist | findstr Vrchost64.exe```

Use the found PID to list active ports

```netstat -aon | findstr <PID>```

<img width="978" height="262" alt="image" src="https://github.com/user-attachments/assets/e3a7c930-cbfe-441d-9e0c-b8720976604d" />

You can also specify a fixed port by changing the robotstudio config file.

```C:\Users\<User>\AppData\Local\ABB\RobotWare\RobotControl_7.12.0\system\appweb.conf```

Read more [here](https://tech-community.robotics.abb.com/t/how-to-change-the-listening-port-of-the-virtual-controller-robotware-6-x-and-7-x/9505).

A quick test is to ask for controller serial in the webbrowser or any Rest Api client.

```https://127.0.0.1:<port>/ctrl/identity/```

If you found the right one it will ask for credentials. Enter  ```Default User/robotics``` and it will show you XML containing controller name and serial.


