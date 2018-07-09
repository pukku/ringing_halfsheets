#!/usr/bin/env perl6
use v6;
sub croak { note $^msg; exit(1); } # because Perl 6 doesn't have the Perl 5 "\n" magic for die

use HTTP::UserAgent;
use XML;
use XML::XPath;
use Template::Mustache;

sub MAIN ( Str :p(:$performance)!, Bool :$bcr = False, Bool :$nagcr = False, Bool :g(:$groff) = False, Bool :f(:$force) = False) {

	my $file = "groff/$performance.groff";
	if $file.IO.e and !$force {
		say "File $file already exists. Will not overwrite.";
		exit();
	}

	my $xml    = get-performance-xml($performance);
	my %parsed = parse-performance-xml($xml);
	my $output = create-groff(%parsed, :$bcr, :$nagcr);

	# save the data
	$file.IO.spurt: $output;
	say "$file written.";

	if $groff {
		shell "/usr/local/bin/groff -Tpdf $file > pdf/$performance.pdf";
		say "groff command run";
	}
}

sub get-performance-xml ($p) {
	my $data = HTTP::UserAgent.new.get("https://bb.ringingworld.co.uk/view.php" ~ "?id={$p}", Accept => 'application/xml');
	$data.is-success or croak("HTTP error retrieving post: {$data.status-line}.");
	return $data.content;
}

sub parse-performance-xml ($xml) {
	my $xmldoc = from-xml($xml);
	my $xpath = XML::XPath.new(document => $xmldoc);
	my %data;

	# gather the straightforward items
	my %spec =
		pid => '/performance/@id',
		guild => '/performance/association/text()',
		date => '/performance/date/text()',
		tower => '/performance/place/@towerbase-id',
		nchanges => '/performance/title/changes/text()',
		method => '/performance/title/method/text()',
		composer => '/performance/composer/text()',
		details => '/performance/details/text()',
		notes => '/performance/footnote/text()',
	;

	for %spec.kv -> $k, $v {
		my $r = $xpath.find($v);
		given $r.WHAT {
			when XML::Text {
				%data{$k} = $r.text().trim();
			}
			when Str {
				%data{$k} = $r;
			}
			when Array { # for gathering the footnotes
				%data{$k} = $r.map({ .text().trim(); }).list;
			}
			default {
				#say $_.perl;
			}
		}
	}

	# gather the ringers
	for | $xpath.find('/performance/ringers/ringer') -> $r {
		my $ringer = $r.contents().map( {.text().trim();}).join(" ");
		if $r.attribs<conductor> { $ringer ~= ' \*[conductor]'; }
		%data<ringers>{$r.attribs<bell>} = $ringer;
	}

	# clean up some things
	%data<pid> .= substr(1);
	if !%data<guild> { %data<guild> = 'Boston Change Ringers'; }

	return %data;
}

sub create-groff (%perf, Bool :$bcr, Bool :$nagcr) {
	my %rdata;
	%rdata<commandline_comment> = "\\# in 'root' dir: groff -Tpdf groff/{ %perf<pid> }.groff > pdf/{ %perf<pid> }.pdf";

	if ($bcr or $nagcr) and ($bcr xor $nagcr) {
		if $bcr { %rdata<urpic><img> = 'bcr'; }
		if $nagcr { %rdata<urpic><img> = 'nagcr'; }
	}
	elsif $bcr and $nagcr {
		;
	}
	else {
		given %perf<guild> {
			when 'North American Guild' { %rdata<urpic><img> = 'nagcr'; }
			when 'MIT Guild of Bellringers' { %rdata<urpic><img> = 'bcr'; }
			when 'Boston Change Ringers' { %rdata<urpic><img> = 'bcr'; }
		}
	}

	%rdata<guild> = %perf<guild>;

	my $date = Date.new(%perf<date>, formatter => &date-formatter);
	%rdata<date> = $date;

	given %perf<tower> {
		when 5852 { %rdata<tower> = "Christ Church in the City of Boston\n.ftsmall\n\\f[I](called \\[lq]Old North\\[rq])\\f[]\n" }
		when 5851 { %rdata<tower> = "The Church of the Advent\n" }
		default { %rdata<tower> = "A tower \@TODO specify\n" }
	};

	given %perf<nchanges> {
		when $_ < 1200 { %rdata<performance_type> = 'performance' };
		when 1200 <= $_ < 5000 { %rdata<performance_type> = 'quarter-peal' };
		when $_ >= 5000 { %rdata<performance_type> = 'peal' };
		default { %rdata<performance_type> = 'weird non-number of changes' };
	};

	%rdata<method> = %perf<nchanges> ~ ' ' ~ %perf<method> ~ "\n";
	if %perf<composer> { %rdata<method> ~= ".ftsmall\ncomposed by { %perf<composer> }\n"; }
	if %perf<details> { %rdata<method> ~= ".fi\n.ftsmall\n{ %perf<details> }\n.nf\n"; }

	my $num = numbells(%perf<method>);
	for sort(%perf<ringers>.keys) -> $n {
		my $l = "\t";
		if $n eq '1' { $l ~= '\*[treble]'; }
		elsif $n > $num { $l ~= '\*[tenor]'; }
		else { $l ~= $n; }
		$l ~= "\t" ~ %perf<ringers>{$n} ~ "\n";
		%rdata<ringers> ~= $l;
	}

	if %perf<notes>.elems {
		%rdata<notes><footnotes> = %perf<notes>.map({ $_ ~ "\n.sp 0.25\n"}).join();
	}

	my $out = Template::Mustache.render($=finish, %rdata);
	$out ~~ s:g/\n\n/\n/; # clean up blank lines, which are anathema to troff
	return $out;
}

sub date-formatter ($self) {
	my $year = $self.year;
	my $month = qw|nul January February March April May June July August September October November December|[$self.month];
	my $day = $self.day;
	my $affix = '\*[st]';
	if 11 <= $day <= 19 { $affix = '\*[th]'; }
	else {
		given $day mod 10 {
			when 0 { $affix = '\*[th]'; }
			when 1 { $affix = '\*[st]'; }
			when 2 { $affix = '\*[nd]'; }
			when 3 { $affix = '\*[rd]'; }
			when 4 <= $_ <= 9 { $affix = '\*[th]'; }
		}
	}
	return "$month $day$affix, $year";
}

sub numbells ($method) {
	my $class = ($method ~~ m/(\w+)$/).Str;
	my %counts =
		fc('Singles') => 3,
		fc('Minimus') => 4,
		fc('Doubles') => 5,
		fc('Minor') => 6,
		fc('Triples') => 7,
		fc('Major') => 8,
		fc('Caters') => 9,
		fc('Royal') => 10,
		fc('Cinques') => 11,
		fc('Maximus') => 12,
	;
	return %counts{fc($class)} // 16;
}

=finish
{{{ commandline_comment }}}
\# see demo.groff for comments
\X'papersize=5.5in,8.5in'
.pl 8.5i
.po 0.5i
.ll 4.5i
.sp |0.5i
.nr def_ps 10
.nr def_vs 15
.nr sml_ps 9
.nr sml_vs 13
.nr flr_ps 20
.nr flr_vs 20
.fam N
.ft NR
.ps \n[def_ps]pt
.vs \n[def_vs]pt
.lg
.kern
.nh
.de GUILD
.ps \\n[def_ps]pt
.vs \\n[def_vs]pt
.nop \f[I]by the\f[]\h[|0.5i]\f[B]\\$1\f[]
..
.de STANZA
.ps \\n[def_ps]pt
.vs \\n[def_vs]pt
.sp
.in 0
.ft NI
.nop \\$1
.br
.in 0.5i
.ft NR
..
.de ftsmall
.ps \\n[sml_ps]pt
.vs \\n[sml_vs]pt
..
.de finalflourish
.ps \\n[flr_ps]pt
.vs \\n[flr_vs]pt
.sp
.in 0
.ce
.nop \f[ZD]\m[red3]\N[167]\m[]\f[]
.br
..
.ds st         \f[B]\v[-.25v]\s[-4]st\s[+4]\v[.25v]\f[]
.ds nd         \f[B]\v[-.25v]\s[-4]nd\s[+4]\v[.25v]\f[]
.ds rd         \f[B]\v[-.25v]\s[-4]rd\s[+4]\v[.25v]\f[]
.ds th         \f[B]\v[-.25v]\s[-4]th\s[+4]\v[.25v]\f[]
.ds treble     \s[-3]TREBLE\s[+3]
.ds tenor      \s[-3]TENOR\s[+3]
.ds conductor  \f[I]\s[-1](conductor)\s[+1]\f[]
.nf
{{#urpic}}
\h[|3.5i]\X'pdf: pdfpic {{{img}}}.pdf -L 1i 1i'
.sp 0.5v
{{/urpic}}
.GUILD "{{{ guild }}}"
.STANZA "on"
{{{ date }}}
.STANZA "at"
{{{ tower }}}
.STANZA "was rung a {{{ performance_type }}} of"
{{{ method }}}
.STANZA "by the ringers"
.in 0
.ta 1iR 1.2i
{{{ ringers }}}
.br
{{#notes}}
.STANZA "with notes"
.fi
{{{ footnotes }}}
.nf
{{/notes}}
.finalflourish
