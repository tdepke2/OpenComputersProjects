
<!-- MARKDOWN-AUTO-DOCS:START (CODE:src=./programs.cfg) -->
<!-- The below code snippet is automatically added from ./programs.cfg -->
```cfg
{
  ["libapptools"] = {
    files = {
      ["master/libapptools/dlog.lua"] = "/lib",
      ["master/libapptools/include.lua"] = "/lib",
    },
    name = "Application Tools Library",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/libapptools",
  },
  ["libdstructs"] = {
    files = {
      ["master/libdstructs/dstructs.lua"] = "/lib",
    },
    name = "Data Structures Library",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/libdstructs",
  },
  ["libmatrix"] = {
    files = {
      ["master/libmatrix/vector.lua"] = "/lib",
      ["master/libmatrix/matrix.lua"] = "/lib",
    },
    name = "Vector/Matrix Library",
    description = "",
    note = "The libapptools package is an optional dependency.",
    authors = "tdepke2",
    repo = "tree/master/libmatrix",
  },
  ["libmnet"] = {
    files = {
      ["master/libmnet/mnet.lua"] = "/lib",
      ["master/libmnet/mrpc.lua"] = "/lib",
    },
    dependencies = {
      ["libapptools"] = "/",
    },
    name = "Mesh Networking and RPC Library",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/libmnet",
  },
  ["libwnet"] = {
    files = {
      ["master/libwnet/packer.lua"] = "/lib",
      ["master/libwnet/wnet.lua"] = "/lib",
    },
    dependencies = {
      ["libapptools"] = "/",
    },
    name = "Prototype Networking Library (old version of libmnet)",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/libwnet",
    hidden = true,
  },
  ["minibuilder"] = {
    files = {
      [":master/minibuilder"] = "//home/minibuilder",
    },
    name = "Automation for Compact Machines Crafting",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/minibuilder",
  },
  ["ocvnc"] = {
    files = {
      [":master/ocvnc"] = "//home/ocvnc",
    },
    name = "VNC Client/Server",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/ocvnc",
  },
  ["oppm_linker"] = {
    files = {
      ["master/oppm_linker/oppm_linker"] = "/man",
      ["master/oppm_linker/oppm_linker.lua"] = "//etc/rc.d",
    },
    name = "OPPM Git Repo Symlink Generator",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/oppm_linker",
  },
  ["tdepke-tests"] = {
    files = {
      
    },
    name = "Unit Tests For tdepke Packages",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/tdepke-tests",
    hidden = true,
  },
  ["tgol"] = {
    files = {
      ["master/tgol/tgol.lua"] = "/bin",
    },
    dependencies = {
      ["libapptools"] = "/",
      ["libdstructs"] = "/",
    },
    name = "Just Another Conways Game of Life",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/tgol",
  },
  ["tquarry"] = {
    files = {
      [":master/tquarry"] = "//home/tquarry",
    },
    dependencies = {
      ["libapptools"] = "/",
    },
    name = "Quarry Bot",
    description = "",
    authors = "tdepke2",
    repo = "tree/master/tquarry",
  },
}
```
<!-- MARKDOWN-AUTO-DOCS:END -->

Some projects for OpenComputers mod.
TODO: Add description, setup instructions, screenshots, etc.

Setting up development environment:
The basic idea is to keep all OpenComputers programs and libraries in one git repository somewhere on disk, and sync these files with copies on a virtual hard disk so a computer/robot has access.
* These steps assume creative mode in single-player (probably works fine on a server though).
* To get started, edit the "config/opencomputers/settings.conf" file in the game install and change "bufferChanges" to false. This will make changes to files outside of the game show up on in-game computers immediately, otherwise you have to restart the server to see changes.
* In game, set up a computer and install OpenOS (preferably using a tier 3 hard disk).
* Install OPPM using the in-game floppy, and "oppm install" any desired packages from the git repo (these get copied over GitHub).
* Outside of the game, "git clone" this repo to some accessible location. It may or may not be safe to put the repo in the same virtual directory as the OpenOS install due to limited space in the virtual hard disks. There is actually an OPPM package that does this called "gitrepo" but I haven't used it. Keeping the repo in a separate place can be a bit more flexible anyways.
* Optionally copy any other files from the git repo (like work-in-progress ones that aren't in a package yet) to the virtual hard disk.
* Use some method to copy file changes in the virtual hard disk to the repo. This can be as simple as copying the files manually each time, but a better method is to use BackupTools:
    * Download BackupTools and create a config to merge files in the virtual hard disk to the repo. All files that are tracked in the repo and in virtual disk should now be synced.
    * Check the backup or use "tree" to confirm files are synced.
    * Whenever changes are ready to be committed, run the backup first and then "git commit".
* It helps to make copies of the hard disk item in game (using cheats) for each computer that is being developed on or tested with. This prevents redundant code across multiple computers. Another way this can be done is by building a RAID and cloning the block to anywhere it is needed. Multiple computers can also access a single RAID when cheats are not an option.
