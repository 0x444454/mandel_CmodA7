# HOW TO BUILD FROM SOURCES

## Requirements

- Xilinx Vivado (tested on version 2025.2).

## Open the project file

Open the ```mandel_CmodA7.xpr``` project file.

NOTE: By default, the project is configured for the Digilent Cmod __A7-35T__ board.  
If instead you have a __Cmod A7-15T__, you need to set ```NCORES = 7``` in the [fb_scanline_writer.sv](src/fb_scanline_writer.sv) file, or you will run out of DSPs.  

## Build
In the "Flow Navigator": "Program and Device" -> "Generate Bitstream".
When done, Vivado will show the "Write Bitstream Complete" in the upper right corner of the UI.

## Run

Once the bitstream has been built, in the "Flow Navigator": "Program and Device" -> "Open Hardware Manager" -> "Program Device" -> [your board].  

NOTE: If "Program Device" is not active, check that the Basys3 USB drivers have been correctly installed.

# LICENSE

Creative Commons, CC BY

https://creativecommons.org/licenses/by/4.0/deed.en

Please add a link to this github project.
