# HOW TO BUILD FROM SOURCES

## Requirements

- Xilinx Vivado (tested on version 2025.2).

## Open the project file

Open the ```mandel_CmodA7.xpr``` project file.

NOTE: If you have a Cmod A7-15T (instead of the A7-35T), you need to set NCORES to 7 in the fb_scanline_writer.sv file.

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
