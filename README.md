This is a Perl 6 program to create half-sheets (using
American sizes, so 8.5x5.5) of ringing performances.

There are hard-coded things related to the Boston (USA)
towers, including special logos and text.

You call it as

		gentroff.pl6 -performance=pid -force -groff -image=bcr

The performance id is from BellBoard. (You can also use `-p`)

By default, it won't do anything for an already existing
performance, in case you've customized the `.groff` output
file. To force it to overwrite the existing file, pass
`-force` (or `-f`).

If you know which logo you want to include, you can pass the
name of a file (without the `.pdf` extension) to the `-image`
(`-i`) parameter. If you don't want an image, specify "`none`".
Otherwise, it tries to guess based on the association
reported by BellBoard.

The program generates a `.groff` output file, and if you want
to run the `groff` command line as a part of the program,
you can pass `-groff` (or `-g`). (This is optional in case
you want to make changes to the output before creating the
`.pdf`.)

This requires `groff` version 1.22 (maybe a lower one will
work, but I don't know). (It must support the `-Tpdf` output
device.)

(I really want a version of `troff` that can handle fonts
without having to jump through hoops.)

