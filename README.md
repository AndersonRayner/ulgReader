# ulgReader
A MATLAB script for importing PX4 ulg files.

The code can process and import large ulg files in an order of seconds and captures log data, messages and header information.

## Usage
Call `ulgReader` as you would any other function.  If you don't specify an input file, a file browser will open where you cna select the file to import.

This code is best used in scripts such that
```
file = 'test.ulg';
fds = ulgReader(file);
```

### Plotting
If you wish to plot all the imported fields (useful for debugging issues), you can optionally add 
```
file = 'test.ulg';
fds = ulgReader(file,1);
```
and the code will automatically generate plots of all the data channels.

## Bugs
Please submit Issues or PRs for any bugs you find.  If a file is failing to import and you're creating an Issue, be sure to include a link to the file to help with debugging.

## License
This work is distributed under the GNU GPLv3 license.
