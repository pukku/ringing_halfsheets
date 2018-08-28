#!/usr/bin/env perl6
use v6;
sub croak { note $^msg; exit(1); } # because Perl 6 doesn't have the Perl 5 "\n" magic for die

use HTTP::UserAgent;
use XML::XPath;
use Template::Mustache;

sub MAIN ( Str :p(:$performance)!, Bool :g(:$groff) = False, Bool :f(:$force) = False,
           Str :i(:$image)? where ( !$image.defined or ($image eq 'none') or "{$image}.pdf".IO.f or croak("{$image}.pdf does not exist for inclusion as image") )
) {

	my $file = "groff/$performance.groff";
	if $file.IO.e and !$force {
		croak "File $file already exists. Will not overwrite.";
	}

	my $xml      = get-performance-xml($performance);
	my %parsed   = parse-performance-xml($xml);
	my $output   = create-groff(%parsed, $image);

	if %parsed<pid> ne $performance {
		croak "Retrieved performance has different id: requested $performance and received %parsed<pid>. Will not continue.";
	}

	# save the data
	$file.IO.spurt: $output;
	say "$file written.";

	if $groff {
		shell "/usr/local/bin/groff -Tpdf $file > pdf/$performance.pdf";
		say "groff command run.";
	}
}

sub get-performance-xml ($p) {
	my $data = HTTP::UserAgent.new.get("https://bb.ringingworld.co.uk/view.php?id={$p}", Accept => 'application/xml');
	$data.is-success or croak("HTTP error retrieving post: {$data.status-line}.");
	return $data.content;
}

sub parse-performance-xml ($xml) {
	my $xpath = XML::XPath.new(xml => $xml);
	my %data;

	# gather the straightforward items
	my %spec =
		pid         => 'substring(/performance/@id,2)',    # the performance ID sadly starts with a 'P' in the XML
		guild       => '/performance/association/text()',
		date        => '/performance/date/text()',
		tower       => '/performance/place/@towerbase-id',
		towernamepl => '/performance/place/place-name[@type="place"]/text()',
		towernamede => '/performance/place/place-name[@type="dedication"]/text()',
		towernameco => '/performance/place/place-name[@type="county"]/text()',
		nchanges    => '/performance/title/changes/text()',
		method      => '/performance/title/method/text()',
		composer    => '/performance/composer/text()',
		details     => '/performance/details/text()',
		notes       => '/performance/footnote/text()',
	;

	for %spec.kv -> $k, $v {
		my $r = $xpath.find($v);
		given $r.WHAT {
			when XML::Text { %data{$k} = $r.text().trim(); }
			when Str       { %data{$k} = $r; }
			when Array     { %data{$k} = $r.map({ .text().trim(); }).list; }
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

	return %data;
}

sub create-groff (%perf, $image) {
	my %rdata;
	%rdata<commandline_comment> = "\\# in 'root' dir: groff -Tpdf groff/{ %perf<pid> }.groff > pdf/{ %perf<pid> }.pdf";

	%rdata<urpic><img> = do given %perf<guild> {
		when defined($image)            { $image  };
		when 'North American Guild'     { 'nagcr' };
		when 'MIT Guild of Bellringers' { 'bcr'   };
		when 'Boston Change Ringers'    { 'bcr'   };
		default                         { 'none'  };
	};
	if (%rdata<urpic><img> eq 'none') { %rdata<urpic> = Nil; }

	defined(%perf<guild>) and %rdata<guild><guild> = %perf<guild>;

	%rdata<date> = Date.new(%perf<date>, formatter => &date-formatter);

	my $towername = "%perf<towernamede>, %perf<towernamepl>, %perf<towernameco>";
	if %perf<tower> ~~ (5851|5852) {
		%rdata<tower>{'t' ~ %perf<tower>}<towername> = $towername;
	}
	else {
		%rdata<tower><tdef><towername> = $towername;
	}

	%rdata<performance_type> = do given %perf<nchanges> {
		when         $_ < 1200 { 'performance' };
		when 1200 <= $_ < 5000 { 'quarter-peal' };
		when 5000 <= $_        { 'peal' };
		default                { 'weird non-number of changes' };
	};

	%rdata<method><method> = "%perf<nchanges> %perf<method>";
	if %perf<composer> { %rdata<method><composed><composer> = %perf<composer>; }
	if %perf<details>  { %rdata<method><details><details> =  %perf<details>; }

	my $num = numbells(%perf<method>);
	for %perf<ringers>.keys.sort(&infix:«<=>») -> $n {
		my $rnum = $n;
		if    $n == '1'  { $rnum = '\*[treble]'; }
		elsif $n >  $num { $rnum = '\*[tenor]'; }
		%rdata<ringers>.push: { num => $rnum, ringer => %perf<ringers>{$n} };
	}

	if %perf<notes>.elems {
		%rdata<notes><footnotes> = [ %perf<notes>.map({ %( 'note' => $_ ); }) ];
	}

	my $out = Template::Mustache.render($=finish, %rdata);
	$out ~~ s:g/ \n ** 2..* /\n/;    # clean up blank lines, which are anathema to troff
	$out .= trans([ '&lt;', '&gt;', '&amp;', '&quot;' ] => ['<', '>', '&', '"']); # fix XML entities
	return $out;
}

sub date-formatter ($self) {
	my $year = $self.year;
	my $month = qw|nul January February March April May June July August September October November December|[$self.month];
	my $day = $self.day;

	# see https://stackoverflow.com/a/13627586/1030573
	my $day_m10  = $day mod 10;
	my $day_m100 = $day mod 100;
	my $affix    = '\*[th]';         # default affix
	if    ($day_m10 == 1) && ($day_m100 != 11) { $affix = '\*[st]'; }
	elsif ($day_m10 == 2) && ($day_m100 != 12) { $affix = '\*[nd]'; }
	elsif ($day_m10 == 3) && ($day_m100 != 13) { $affix = '\*[rd]'; }

	return "$month $day$affix, $year";
}

sub numbells ($method) {
	my $class = ($method ~~ m/(\w+)$/).Str;
	my @counts = qw|nul impossible impossible Singles Minimus Doubles Minor Triples Major Caters Royal Cinques Maximus|.map: &fc;
	return @counts.first(fc($class), :k) // 16;
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
.nop \f[I]for the\f[]\h[|0.5i]\f[B]\\$1\f[]
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
{{# urpic}}
\h[|3.0i]\X'pdf: pdfpic {{{img}}}.pdf -L 1.5i 1.5i'
.sp 0.5v
{{/ urpic}}
{{# guild}}
.GUILD "{{{ guild }}}"
{{/ guild}}
.STANZA "on"
{{{ date }}}
.STANZA "at"
{{# tower }}
{{# t5851 }}
The Church of the Advent
{{/ t5851 }}
{{# t5852 }}
Christ Church in the City of Boston
.ftsmall
\f[I](called \[lq]Old North\[rq])\f[]
{{/ t5852 }}
{{# tdef }}
{{{ towername }}}
{{/ tdef }}
{{/ tower }}
.STANZA "was rung a {{{ performance_type }}} of"
{{# method }}
{{{ method }}}
{{# composed }}
.ftsmall
composed by {{{ composer }}}
{{/ composed }}
{{# details }}
.fi
.ftsmall
{{{ details }}}
.nf
{{/ details }}
{{/ method }}
.STANZA "by the ringers"
.in 0
.ta 1iR 1.2i
{{# ringers }}
	{{{ num }}}	{{{ ringer }}}
{{/ ringers }}
.br
{{# notes}}
.STANZA "with notes"
.fi
{{# footnotes }}
{{{ note }}}
.sp 0.25
{{/ footnotes }}
.nf
{{/ notes}}
.finalflourish
