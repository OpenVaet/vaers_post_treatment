#!/usr/bin/perl
use strict;
use warnings;
use 5.30.0;
no autovivification;
binmode STDOUT, ":utf8";
use utf8;
use Data::Printer;
use Data::Dumper;
use File::Path qw(make_path);
use Text::CSV qw( csv );
use FindBin;
use Scalar::Util qw(looks_like_number);
use lib "$FindBin::Bin/lib";
use JSON;
use HTTP::Tiny;
use Time::HiRes qw(time);

# ---- Files ----
my $archive_file      = 'data_archive.json';
my $ages_input_file   = 'age_from_text_ollama.csv';     # produced by layer 1 (verify_ages.pl)
my $outcomes_out_file = 'outcomes_minors_ollama.csv';   # this script's output (resume target)

# ---- Ollama config ----
my $ollama_model = 'gemma4:e4b';                        # must match `ollama list`
my $ollama_url   = 'http://127.0.0.1:11434/api/generate';

# ---- Load data ----
my %archive_data       = ();
my %minor_ages         = ();   # vaers_id => age (years), only when known and <= 18
my %outcomes_processed = ();   # vaers_id => 1, for resume

load_archive();
load_minor_ages();
load_outcomes_processed();

# ---- Build worklist (same shape/feel as your first script) ----
my ($current, $total) = (0, 0);

for my $vaers_id (sort { $a <=> $b } keys %minor_ages) {
	next if exists $outcomes_processed{$vaers_id};
	next unless exists $archive_data{$vaers_id};
	next unless defined $archive_data{$vaers_id}->{'symptom_text'};
	$total++;
}

say "Minors (age <= 18) found in layer-1 output : " . scalar(keys %minor_ages);
say "Already processed                          : " . scalar(keys %outcomes_processed);
say "Pending                                    : $total";

my $started_at = time;

for my $vaers_id (sort { $a <=> $b } keys %minor_ages) {
	next if exists $outcomes_processed{$vaers_id};
	next unless exists $archive_data{$vaers_id};
	my $symptoms_text = $archive_data{$vaers_id}->{'symptom_text'};
	next unless defined $symptoms_text;
	my $file_year     = $archive_data{$vaers_id}->{'file_year'} // die;

	$current++;

	my $elapsed_seconds = time - $started_at;
	my $elapsed_minutes = $elapsed_seconds / 60;
	my $per_minute      = $elapsed_minutes > 0 ? ($current / $elapsed_minutes) : 0;
	my $remaining       = $total - $current;
	my $eta_minutes     = $per_minute > 0 ? ($remaining / $per_minute) : 0;
	my $eta_str         = $per_minute > 0 ? format_eta($eta_minutes) : '--h --m --s';

	my $age = $minor_ages{$vaers_id};

	STDOUT->printflush(
		sprintf(
			"\rClassifying minor outcomes - [%d] - age=%-5s - [%d / %d] | %.2f/min | ETA: %s   ",
			$file_year,
			(defined $age ? $age : '?'),
			$current,
			$total,
			$per_minute,
			$eta_str,
		)
	);

	my $res = classify_outcomes_with_ollama($symptoms_text);

	append_outcome_processed($vaers_id, $age, $res);
}

say "";   # newline after progress line

# ---------------------------------------------------------------------------

sub load_archive {
	open my $in, '<', $archive_file or die "Cannot open $archive_file: $!";
	my $json;
	while (<$in>) { $json .= $_ }
	close $in;
	$json = decode_json($json);
	%archive_data = %$json;
}

sub load_minor_ages {
	# 1) Primary source: archive_data{$vaers_id}{age_years}.
	#    If it has a numeric value, that is the ground truth.
	my $from_archive = 0;
	# for my $vaers_id (keys %archive_data) {
	# 	my $age_years = $archive_data{$vaers_id}->{'age_years'};
	# 	next unless defined $age_years && $age_years ne '' && looks_like_number($age_years);

	# 	my $age_num = $age_years + 0;
	# 	next if $age_num < 0 || $age_num > 120;   # sanity bounds
	# 	next unless $age_num <= 18;

	# 	$minor_ages{$vaers_id} = $age_num;
	# 	$from_archive++;
	# }

	# 2) Fallback: only when age_years is missing/empty in the archive,
	#    use the age extracted by the layer-1 script (status=ok).
	my $from_layer1 = 0;
	if (-f $ages_input_file) {
		open my $in, '<:utf8', $ages_input_file
			or die "Cannot open $ages_input_file: $!";

		while (<$in>) {
			chomp;
			next unless length $_;
			next if /^vaers_id\b/;   # skip header

			# header layout : vaers_id;age;status;evidence
			my ($vaers_id, $age, $status, $evidence) = split /;/, $_, 4;
			next unless defined $vaers_id && length $vaers_id;
			next unless defined $status   && $status eq 'ok';
			next unless defined $age      && $age ne 'null' && looks_like_number($age);

			# Skip if the archive already has a usable age_years for this report
			my $archive_age = $archive_data{$vaers_id}->{'age_years'};
			next if defined $archive_age && $archive_age ne '' && looks_like_number($archive_age);

			my $age_num = $age + 0;
			next unless $age_num <= 18;

			$minor_ages{$vaers_id} = $age_num;
			$from_layer1++;
		}
		close $in;
	} else {
		warn "Layer-1 file '$ages_input_file' not found - skipping fallback source.\n";
	}

	say "Minors from archive age_years              : $from_archive";
	say "Minors from layer-1 fallback (no age_years): $from_layer1";
}

sub load_outcomes_processed {
	if (-f $outcomes_out_file) {
		open my $in, '<:utf8', $outcomes_out_file or die $!;
		while (<$in>) {
			chomp;
			next unless length $_;
			next if /^vaers_id\b/;   # skip header
			my ($vaers_id) = split /;/, $_;
			$outcomes_processed{$vaers_id} = 1 if defined $vaers_id && length $vaers_id;
		}
		close $in;
	}
}

sub format_eta {
	my ($minutes) = @_;
	$minutes ||= 0;

	my $total_seconds = int($minutes * 60);
	my $hours    = int($total_seconds / 3600);
	my $minutes2 = int(($total_seconds % 3600) / 60);
	my $seconds  = $total_seconds % 60;

	return sprintf("%02dh %02dm %02ds", $hours, $minutes2, $seconds);
}

sub append_outcome_processed {
	my ($vaers_id, $age, $res) = @_;

	my $life_threatening = $res->{life_threatening} // 'error';
	my $subject_died     = $res->{subject_died}     // 'error';
	my $disability       = $res->{disability}       // 'error';
	my $status           = $res->{status}           // 'error';
	my $evidence         = $res->{evidence}         // '';

	# Format age (whole / decimal) the same way as layer 1 did
	my $age_out = 'null';
	if (defined $age && looks_like_number($age)) {
		if ($age == int($age)) {
			$age_out = int($age);
		} else {
			$age_out = sprintf("%.2f", $age);
			$age_out =~ s/0+$//;
			$age_out =~ s/\.$//;
		}
	}

	# Sanitize CSV-bound fields
	for ($life_threatening, $subject_died, $disability, $status, $evidence) {
		$_ //= '';
		s/[\r\n]+/ /g;
		s/;/,/g;
		s/\s{2,}/ /g;
		s/^\s+|\s+$//g;
	}

	my ($dir) = $outcomes_out_file =~ m{^(.*)/[^/]+$};
	if ($dir && !-d $dir) {
		make_path($dir);
	}

	my $needs_header = !-f $outcomes_out_file;

	open my $out, '>>:utf8', $outcomes_out_file
		or die "Cannot open $outcomes_out_file for append: $!";

	if ($needs_header) {
		print $out "vaers_id;age;life_threatening;subject_died;disability;status;evidence\n";
	}

	print $out join(
		';',
		$vaers_id,
		$age_out,
		$life_threatening,
		$subject_died,
		$disability,
		$status,
		$evidence,
	), "\n";

	close $out;

	$outcomes_processed{$vaers_id} = 1;
}

sub classify_outcomes_with_ollama {
	my ($symptoms_text) = @_;
	$symptoms_text //= '';

	# Keep prompt size reasonable
	my $MAX_CHARS = 6000;
	$symptoms_text = substr($symptoms_text, 0, $MAX_CHARS) if length($symptoms_text) > $MAX_CHARS;

	my $prompt = join "\n",
		'You are reviewing a VAERS adverse-event report concerning a patient aged 18 or under.',
		'Classify the report on THREE outcomes. Each answer MUST be exactly "yes" or "no".',
		'',
		'- life_threatening: did the subject experience a LIFE-THREATENING event attributable to the reported reaction (e.g. anaphylaxis, cardiac arrest, severe organ failure, ICU admission for vital threat, "nearly died", "code blue")? Answer "no" if the event was serious but not described as life-threatening.',
		'- subject_died: did ANY person die in this report? Answer "yes" if the subject of the report died (wording like "expired", "deceased", "died", "death", "fatal outcome") OR if a child involved in the report died (e.g. miscarriage, stillbirth, neonatal death, infant death of the subject\'s offspring). Answer "no" if no death is reported.',
		'- disability: was there a permanent or long-lasting disability or incapacity attributed to the event (e.g. paralysis, permanent neurological damage, persistent loss of function, "permanent injury")? Transient symptoms = "no".',
		'',
		'If something is unclear, ambiguous, or merely speculative => answer "no".',
		'Evidence: short snippet (<=160 chars) supporting your answers; empty string if none.',
		'',
		'Text:',
		$symptoms_text;

	my $yesno  = { type => "string", enum => ["yes", "no"] };
	my $schema = {
		type       => "object",
		properties => {
			life_threatening => $yesno,
			subject_died     => $yesno,
			disability       => $yesno,
			evidence         => { type => "string" },
		},
		required => [qw(life_threatening subject_died disability evidence)],
		additionalProperties => JSON::false,
	};

	my $req = {
		model      => $ollama_model,
		prompt     => $prompt,
		stream     => JSON::false,
		format     => $schema,
		keep_alive => "5m",
	};

	my $http = HTTP::Tiny->new(timeout => 120);

	my $resp = $http->post(
		$ollama_url,
		{
			headers => { 'content-type' => 'application/json' },
			content => encode_json($req),
		}
	);

	if (!$resp->{success}) {
		warn "\nOllama HTTP error: $resp->{status} $resp->{reason}\n";
		return { status => 'error', evidence => '' };
	}

	my $body = $resp->{content} // '';
	my $api;
	eval { $api = decode_json($body); 1 } or do {
		warn "\nOllama API JSON parse failed. Body was:\n$body\n";
		return { status => 'error', evidence => '' };
	};

	my $model_text = $api->{response} // '';
	$model_text =~ s/^\s+//;
	$model_text =~ s/\s+$//;

	my $data;
	eval { $data = decode_json($model_text); 1 } or do {
		# Salvage attempt
		if ($model_text =~ /(\{.*\})/s) {
			my $cand = $1;
			eval { $data = decode_json($cand); 1 } or do {};
		}
		if (!$data) {
			warn "\nModel JSON parse failed. Model output was:\n$model_text\n";
			return { status => 'error', evidence => '' };
		}
	};

	# Normalise outputs
	my %out;
	for my $k (qw(life_threatening subject_died disability)) {
		my $v = lc($data->{$k} // '');
		$out{$k} = ($v eq 'yes' || $v eq 'no') ? $v : 'no';
	}

	my $evidence = $data->{evidence} // '';
	$evidence =~ s/[\r\n]+/ /g;
	$evidence =~ s/\s{2,}/ /g;
	$evidence = substr($evidence, 0, 180);

	$out{status}   = 'ok';
	$out{evidence} = $evidence;

	return \%out;
}