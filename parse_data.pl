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
use Math::Round qw(nearest);
use Date::DayOfWeek;
use Date::WeekNumber qw/ iso_week_number /;
use Encode;
use Encode::Unicode;
use JSON;
use FindBin;
use Scalar::Util qw(looks_like_number);
use File::stat;
use lib "$FindBin::Bin/lib";
use JSON;
use File::Path qw(make_path);
use HTTP::Tiny;

my %archive_data                = ();
my %stats                       = ();

# ------------------------------
my $data_folder                 = 'data';

# Verifying in current .ZIP file if things have been deleted.
my %years = ();

for my $data_file (glob "$data_folder/*VAERSDATA.csv") {
	my ($year) = $data_file =~ /$data_folder\/(....)VAERSDATA\.csv/;
	next unless $year;
	$years{$year} = 1;
}

my $total_files  = keys %years;
my $current_file = 0;

for my $year (sort{$a <=> $b} keys %years) {
	$current_file++;
	STDOUT->printflush("\rParsing data - [$current_file / $total_files]");
	parse_data($year);
}

my $total_reports = keys %archive_data;
say "total_reports : $total_reports";

# Printing data.
open my $out, '>:utf8', 'data_archive.json';
print $out encode_json\%archive_data;
close $out;

delete $stats{'without_age_by_date_ids'};

sub parse_data {
	my $file_year = shift;

	# Configuring expected files ; dying if they aren't found.
	my $data_file     = "$data_folder/$file_year" . "VAERSDATA.csv";
	my $symptoms_file = "$data_folder/$file_year" . "VAERSSYMPTOMS.csv";
	my $vax_file      = "$data_folder/$file_year" . "VAERSVAX.csv";
	die "missing mandatory file in [$data_folder]" if !-f $data_file || !-f $symptoms_file || !-f $vax_file;
	say "data_file     : $data_file";
	say "symptoms_file : $symptoms_file";
	say "vax_file      : $vax_file";

	# Fetching notices - vaccines relations.
	open my $vax_in, '<:', $vax_file;
	my $expected_vals;
	my $vax_csv     = Text::CSV_XS->new ({ binary => 1 });
	my %vax_labels  = ();
	my %reports_vax = ();
	my $row_num = 0;
	while (<$vax_in>) {
		$row_num++;

		# Fixing some poor encodings by replacing special chars by their UTF8 equivalents or removing them.
		$_ =~ s/–/-/g;
		$_ =~ s/–/-/g;
		$_ =~ s/ –D/ -D/g;
		$_ =~ s/\\xA0//g;
		$_ =~ s/~/--:--/g;
    	$_ =~ s/ / /g;
    	$_ =~ s// /g;
    	$_ =~ s// /g;
    	$_ =~ s/\r//g;
		$_ =~ s/[\x{80}-\x{FF}\x{1C}\x{02}\x{05}\x{06}\x{7F}\x{17}\x{10}]//g;
		$_ =~ s/\x{1F}/./g;

		# Verifying line.
		my $line = $_;
		$line = decode("ascii", $line);
		for (/[^\n -~]/g) {
		    printf "Bad character: %02x\n", ord $_;
		    die;
		}

		# First row = line labels.
		if ($row_num == 1) {
			my @labels  = split ',', $line;
			my $label_n = 0;
			for my $label (@labels) {
				$vax_labels{$label_n} = $label;
				$label_n++;
			}
			$expected_vals = keys %vax_labels;
		} else {

			# Verifying we have the expected number of values.
			open my $fh, "<", \$_;
			my $row = $vax_csv->getline ($fh);
			my @row = @$row;
			die scalar @row . " != $expected_vals" unless scalar @row == $expected_vals;
			my $val_n  = 0;
			my %values = ();
			for my $value (@row) {
				my $label = $vax_labels{$val_n} // die;
				$values{$label} = $value;
				$val_n++;
			}
			my $dose         = $values{'VAX_DOSE_SERIES'};
			my $vaers_id     = $values{'VAERS_ID'} // die;
			my $manufacturer = $values{'VAX_MANU'} // die;
			my $vax_type     = $values{'VAX_TYPE'} // die;
			my $vax_name     = $values{"VAX_NAME\n"} // 'UKN';
        	my $drug_name    = "$manufacturer - $vax_type - $vax_name";
        	my ($drug_category,
        		$drug_short_name) = substance_synthesis($drug_name);
			my %o                 = ();
			$o{'drug_category'}   = $drug_category;
			$o{'drug_short_name'} = $drug_short_name;
			$o{'vax_name'}        = $vax_name;
			$o{'dose'}            = $dose;
			push @{$reports_vax{$vaers_id}->{'vaccines'}}, \%o;
		}
	}
	close $vax_in;

	# Fetching notices - symptoms relations.
	open my $symptoms_in, '<:', $symptoms_file;
	my $symptoms_csv = Text::CSV_XS->new ({ binary => 1 });
	my %symptoms_labels = ();
	$row_num = 0;
	my %report_symptoms = ();
	while (<$symptoms_in>) {
		$row_num++;

		# Fixing some poor encodings by replacing special chars by their UTF8 equivalents.
		$_ =~ s/–/-/g;
		$_ =~ s/–/-/g;
		$_ =~ s/ –D/ -D/g;
		$_ =~ s/\\xA0//g;
		$_ =~ s/~/--:--/g;
    	$_ =~ s/ / /g;
    	$_ =~ s// /g;
    	$_ =~ s// /g;
    	$_ =~ s/\r//g;
		$_ =~ s/[\x{80}-\x{FF}\x{1C}\x{02}\x{05}\x{06}\x{7F}\x{17}\x{10}]//g;
		$_ =~ s/\x{1F}/./g;

		# Verifying line.
		my $line = $_;
		$line = decode("ascii", $line);
		for (/[^\n -~]/g) {
		    printf "Bad character: %02x\n", ord $_;
		    die;
		}

		# First row = line labels.
		if ($row_num == 1) {
			my @labels = split ',', $line;
			my $label_n = 0;
			for my $label (@labels) {
				$symptoms_labels{$label_n} = $label;
				$label_n++;
			}
			$expected_vals = keys %symptoms_labels;
		} else {

			# Verifying we have the expected number of values.
			open my $fh, "<", \$_;
			my $row = $symptoms_csv->getline ($fh);
			my @row = @$row;
			die scalar @row . " != $expected_vals" unless scalar @row == $expected_vals;
			my $val_n  = 0;
			my %values = ();
			for my $value (@row) {
				my $label = $symptoms_labels{$val_n} // die;
				$values{$label} = $value;
				$val_n++;
			}
			my $vaers_id  = $values{'VAERS_ID'} // die;
			my $symptom1 = $values{'SYMPTOM1'} // die;
			my $symptom2 = $values{'SYMPTOM2'};
			my $symptom3 = $values{'SYMPTOM3'};
			my $symptom4 = $values{'SYMPTOM4'};
			my $symptom5 = $values{'SYMPTOM5'};
			my @symptoms = ($symptom1, $symptom2, $symptom3, $symptom4, $symptom5);
			for my $symptom_name (@symptoms) {
				next unless $symptom_name && length $symptom_name >= 1;
				$report_symptoms{$vaers_id}->{$symptom_name} = 1;
			}
		}
	}
	close $symptoms_in;

	# Fetching notices.
	open my $data_in, '<:', $data_file;
	$row_num          = 0;
	my %data_labels   = ();
	my $data_csv      = Text::CSV_XS->new ({ binary => 1 });
	my %country_codes = ();
	my ($undefined_age, $latest_report) = (0, 0);
	while (<$data_in>) {
		$row_num++;

		# Fixing some poor encodings by replacing special chars by their UTF8 equivalents.
		$_ =~ s/–/-/g;
		$_ =~ s/–/-/g;
		$_ =~ s/ –D/ -D/g;
		$_ =~ s/\\xA0//g;
		$_ =~ s/~/--:--/g;
    	$_ =~ s/ / /g;
    	$_ =~ s// /g;
    	$_ =~ s// /g;
    	$_ =~ s/\r//g;
		$_ =~ s/[\x{80}-\x{FF}\x{1C}\x{02}\x{05}\x{06}\x{7F}\x{17}\x{10}]//g;
		$_ =~ s/\x{1F}/./g;

		# Verifying line.
		my $line = $_;
		$line = decode("ascii", $line);
		for (/[^\n -~]/g) {
		    printf "Bad character: %02x\n", ord $_;
		    die;
		}

		# First row = line labels.
		if ($row_num == 1) {
			my @labels = split ',', $line;
			my $label_n = 0;
			for my $label (@labels) {
				$data_labels{$label_n} = $label;
				$label_n++;
			}
			$expected_vals = keys %data_labels;
		} else {

			# Verifying we have the expected number of values.
			open my $fh, "<", \$_;
			my $row = $data_csv->getline ($fh);
			my @row = @$row;
			die scalar @row . " != $expected_vals" unless scalar @row == $expected_vals;
			my $val_n  = 0;
			my %values = ();
			for my $value (@row) {
				my $label = $data_labels{$val_n} // die;
				$values{$label} = $value;
				$val_n++;
			}

			# Retrieving report data we care about.
			my $vaers_id             = $values{'VAERS_ID'}                  // die;
			# Skipping the report if no Covid vaccine is associated.
			next unless exists $reports_vax{$vaers_id};
			my $vaers_reception_date = $values{'RECVDATE'}                  // die;
			my $onset_date           = $values{'ONSET_DATE'};
			my $age_years            = $values{'AGE_YRS'}                   // die;
			my $cdc_sex              = $values{'SEX'}                       // die;
			my ($sex_name, $sex);
			if ($cdc_sex eq 'F') {
				$sex   = 1;
				$sex_name = 'Female';
			} elsif ($cdc_sex eq 'M') {
				$sex   = 2;
				$sex_name = 'Male';
			} elsif ($cdc_sex eq 'U') {
				$sex   = 3;
				$sex_name = 'Unknown';
			} else {
				$sex   = 3;
				$sex_name = 'Unknown';
			}
			my $vax_date                = $values{'VAX_DATE'};
			my $deceased_date           = $values{'DATEDIED'};
			my $symptom_text            = $values{'SYMPTOM_TEXT'};
			my $vax_administered_by     = $values{'V_ADMINBY'};
			my $hospitalized            = $values{'HOSPITAL'};
			my $permanent_disability    = $values{'DISABLE'};
			my $life_threatening        = $values{'L_THREAT'};
			my $imm_project_number      = $values{'SPLTTYPE'};
			my $patient_died            = $values{'DIED'};
			$age_years                  = undef unless defined $age_years        && length $age_years            >= 1;
			$hospitalized               = 0 unless defined $hospitalized         && length $hospitalized         >= 1;
			$permanent_disability       = 0 unless defined $permanent_disability && length $permanent_disability >= 1;
			$life_threatening           = 0 unless defined $life_threatening     && length $life_threatening     >= 1;
			$patient_died               = 0 unless defined $patient_died         && length $patient_died         >= 1;
			$patient_died               = 1 if defined $patient_died             && $patient_died         eq 'Y';
			$hospitalized               = 1 if defined $hospitalized             && $hospitalized         eq 'Y';
			$permanent_disability       = 1 if defined $permanent_disability     && $permanent_disability eq 'Y';
			$life_threatening           = 1 if defined $life_threatening         && $life_threatening     eq 'Y';
		    $vaers_reception_date       = convert_date($vaers_reception_date);
		    $vax_date                   = convert_date($vax_date)                if $vax_date;
		    $deceased_date              = convert_date($deceased_date)           if $deceased_date;
		    $onset_date                 = convert_date($onset_date)              if $onset_date;
			$onset_date                 = undef unless defined $onset_date       && length $onset_date    >= 1;
			$deceased_date              = undef unless defined $deceased_date    && length $deceased_date >= 1;
			$vax_date                   = undef unless defined $vax_date         && length $vax_date      >= 1;
			$age_years                  = undef unless defined $age_years        && length $age_years     >= 1;
			my ($age_group_id,
				$age_group_name);
			if (defined $age_years) {
				($age_group_id,
					$age_group_name) = age_to_age_group($age_years);
			}
		    my ($reception_year, $reception_month, $reception_day) = split '-', $vaers_reception_date;
		    my $comp_date  = "$reception_year$reception_month$reception_day";
		    $latest_report = $comp_date if $latest_report < $comp_date;

			# Inserting the report symptoms if unknown.
			my @symptoms_listed  = ();
			for my $symptom_name (sort keys %{$report_symptoms{$vaers_id}}) {
				push @symptoms_listed, $symptom_name;
			}

			# Inserting the vaccines data.
			my @vaccines_listed  = @{$reports_vax{$vaers_id}->{'vaccines'}};
			$undefined_age++ unless defined $age_group_name;
			$archive_data{$vaers_id}->{'vaccines_listed'}      = \@vaccines_listed;
			$archive_data{$vaers_id}->{'symptom_text'}         = $symptom_text;
			$archive_data{$vaers_id}->{'age_years'}            = $age_years;
			$archive_data{$vaers_id}->{'file_year'}            = $file_year;
			$archive_data{$vaers_id}->{'comp_date'}            = $comp_date;
			$archive_data{$vaers_id}->{'age_group_name'}       = $age_group_name;
			$archive_data{$vaers_id}->{'onset_date'}           = $onset_date;
			$archive_data{$vaers_id}->{'deceased_date'}        = $deceased_date;
			$archive_data{$vaers_id}->{'sex_name'}             = $sex_name;
			$archive_data{$vaers_id}->{'hospitalized'}         = $hospitalized;
			$archive_data{$vaers_id}->{'imm_project_number'}   = $imm_project_number;
			$archive_data{$vaers_id}->{'patient_died'}         = $patient_died;
			$archive_data{$vaers_id}->{'permanent_disability'} = $permanent_disability;
			$archive_data{$vaers_id}->{'life_threatening'}     = $life_threatening;
			$archive_data{$vaers_id}->{'vax_date'}             = $vax_date;
			$archive_data{$vaers_id}->{'vax_administered_by'}  = $vax_administered_by;
			$archive_data{$vaers_id}->{'vaers_reception_date'} = $vaers_reception_date;
			$archive_data{$vaers_id}->{'symptoms_listed'}      = \@symptoms_listed;
		}
	}
	close $data_in;
	say "latest_report : $latest_report";
	say "undefined_age : $undefined_age";
}

sub age_to_age_group {
	my ($age_years) = @_;
	return (0, 'Unknown') unless defined $age_years && length $age_years >= 1;
	my ($age_group_id, $age_group_name);
	if ($age_years <= 1.99) {
		$age_group_id = '1';
		$age_group_name       = '<2 Years';
	} elsif ($age_years >= 2 && $age_years <= 4.99) {
		$age_group_id = '2';
		$age_group_name = '2 - 4 Years';
	} elsif ($age_years >= 5 && $age_years <= 11.99) {
		$age_group_id = '3';
		$age_group_name = '5 - 11 Years';
	} elsif ($age_years >= 12 && $age_years <= 17.99) {
		$age_group_id = '4';
		$age_group_name = '12 - 17 Years';
	} elsif ($age_years >= 18 && $age_years <= 24.99) {
		$age_group_id = '5';
		$age_group_name = '18 - 24 Years';
	} elsif ($age_years >= 25 && $age_years <= 49.99) {
		$age_group_id = '6';
		$age_group_name = '25 - 49 Years';
	} elsif ($age_years >= 50 && $age_years <= 64.99) {
		$age_group_id = '6';
		$age_group_name = '50 - 64 Years';
	} elsif ($age_years >= 65) {
		$age_group_id = '7';
		$age_group_name = '65+ Years';
	} else {
		die "age_years : $age_years";
	}
	return ($age_group_id, $age_group_name);
}

sub convert_date {
	my ($dt) = @_;
	my ($m, $d, $y) = split "\/", $dt;
	die unless defined $d && defined $m && defined $y;
	return "$y-$m-$d";
}

sub substance_synthesis {
    my ($drug_name) = @_;
    return ('OTHER', undef) if
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU4 - INFLUENZA (SEASONAL) (FLULAVAL QUADRIVALENT)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - RV1 - ROTAVIRUS (ROTARIX)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - UNK - VACCINE NOT SPECIFIED (NO BRAND NAME)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - MENB - MENINGOCOCCAL B (BEXSERO)' ||
        $drug_name eq 'MERCK & CO. INC. - HIBV - HIB (PEDVAXHIB)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - MNQ - MENINGOCOCCAL CONJUGATE (MENVEO)' ||
        $drug_name eq 'BERNA BIOTECH, LTD - TYP - TYPHOID LIVE ORAL TY21A (VIVOTIF)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - HIBV - HIB (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - FLU3 - INFLUENZA (SEASONAL) (FLUZONE)' ||
        $drug_name eq 'AVENTIS PASTEUR - FLU3 - INFLUENZA (SEASONAL) (FLUZONE)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - MENHIB - MENINGOCOCCAL CONJUGATE + HIB (MENITORIX)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLUA3 - INFLUENZA (SEASONAL) (FLUAD)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - RVX - ROTAVIRUS (NO BRAND NAME)' ||
        $drug_name eq 'MERCK & CO. INC. - RV5 - ROTAVIRUS (ROTATEQ)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - HPV2 - HPV (CERVARIX)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - MMR - MEASLES + MUMPS + RUBELLA (PRIORIX)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - VARCEL - VARICELLA (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - FLU4 - INFLUENZA (SEASONAL) (FLUZONE HIGH-DOSE QUADRIVALENT)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - PPV - PNEUMO (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - PNC10 - PNEUMO (SYNFLORIX)' ||
        $drug_name eq 'MERCK & CO. INC. - VARCEL - VARICELLA (VARIVAX)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU(H1N1) - INFLUENZA (H1N1) (H1N1 (MONOVALENT) (GSK))' ||
        $drug_name eq 'MERCK & CO. INC. - HEPA - HEP A (VAQTA)' ||
        $drug_name eq 'MASS. PUB HLTH BIOL LAB - UNK - VACCINE NOT SPECIFIED (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - HEPATYP - HEP A + TYP (HEPATYRIX)' ||
        $drug_name eq 'SANOFI PASTEUR - FLU3 - INFLUENZA (SEASONAL) (FLUZONE HIGH-DOSE)' ||
        $drug_name eq 'MERCK & CO. INC. - PPV - PNEUMO (PNEUMOVAX)' ||
        $drug_name eq 'MEDEVA PHARMA, LTD. - FLU3 - INFLUENZA (SEASONAL) (FLUVIRIN)' ||
        $drug_name eq 'SANOFI PASTEUR - BCG - BCG (MYCOBAX)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - LYME - LYME (LYMERIX)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU3 - INFLUENZA (SEASONAL) (TIV DRESDEN)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU3 - INFLUENZA (SEASONAL) (FLULAVAL)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU4 - INFLUENZA (SEASONAL) (QIV QUEBEC)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU4 - INFLUENZA (SEASONAL) (QIV DRESDEN)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU3 - INFLUENZA (SEASONAL) (FLUARIX)' ||
        $drug_name eq 'PROTEIN SCIENCES CORPORATION - FLUR4 - INFLUENZA (SEASONAL) (FLUBLOK QUADRIVALENT)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - UNK - VACCINE NOT SPECIFIED (OTHER)' ||
        $drug_name eq 'PFIZER\WYETH - MENB - MENINGOCOCCAL B (TRUMENBA)' ||
        $drug_name eq 'MERCK & CO. INC. - MMRV - MEASLES + MUMPS + RUBELLA + VARICELLA (PROQUAD)' ||
        $drug_name eq 'MERCK & CO. INC. - MMR - MEASLES + MUMPS + RUBELLA (MMR II)' ||
        $drug_name eq 'SEQIRUS, INC. - FLUC4 - INFLUENZA (SEASONAL) (FLUCELVAX QUADRIVALENT)' ||
        $drug_name eq 'MERCK & CO. INC. - HPV9 - HPV (GARDASIL 9)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - VARZOS - ZOSTER (SHINGRIX)' ||
        $drug_name eq 'PAXVAX - CHOL - CHOLERA (VAXCHORA)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - LYME - LYME (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MU - MUMPS (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - VARZOS - ZOSTER (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - HIBV - HIB (ACTHIB)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - MNQHIB - MENINGOCOCCAL C & Y + HIB (MENHIBRIX)' ||
        $drug_name eq 'PFIZER\WYETH - PNC - PNEUMO (PREVNAR)' ||
        $drug_name eq 'SANOFI PASTEUR - TYP - TYPHOID VI POLYSACCHARIDE (TYPHIM VI)' ||
        $drug_name eq 'MERCK & CO. INC. - VARZOS - ZOSTER LIVE (ZOSTAVAX)' ||
        $drug_name eq 'MERCK & CO. INC. - RUB - RUBELLA (MERUVAX II)' ||
        $drug_name eq 'PFIZER\WYETH - PNC13 - PNEUMO (PREVNAR13)' ||
        $drug_name eq 'SANOFI PASTEUR - FLU3 - INFLUENZA (SEASONAL) (FLUZONE)' ||
        $drug_name eq 'MERCK & CO. INC. - HPV4 - HPV (GARDASIL)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - RUB - RUBELLA (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MEN - MENINGOCOCCAL (NO BRAND NAME)' ||
        $drug_name eq 'SEQIRUS, INC. - FLUA4 - INFLUENZA (SEASONAL) (FLUAD QUADRIVALENT)' ||
        $drug_name eq 'PFIZER\WYETH - PNC20 - PNEUMO (PREVNAR20)' ||
        $drug_name eq 'LEDERLE PRAXSIS - HIBV - HIB POLYSACCHARIDE (FOREIGN)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - SMALL - SMALLPOX (NO BRAND NAME)' ||
        $drug_name eq 'MEDIMMUNE VACCINES, INC. - FLUN(H1N1) - INFLUENZA (H1N1) (H1N1 (MONOVALENT) (MEDIMMUNE))' ||
        $drug_name eq 'MEDIMMUNE VACCINES, INC. - FLUN3 - INFLUENZA (SEASONAL) (FLUENZ)' ||
        $drug_name eq 'MEDIMMUNE VACCINES, INC. - FLUN4 - INFLUENZA (SEASONAL) (FLUENZ TETRA)' ||
        $drug_name eq 'MERCK & CO. INC. - EBZR - EBOLA ZAIRE (ERVEBO)' ||
        $drug_name eq 'MERCK & CO. INC. - MEA - MEASLES (ATTENUVAX)' ||
        $drug_name eq 'MERCK & CO. INC. - MEA - MEASLES (FOREIGN)' ||
        $drug_name eq 'MERCK & CO. INC. - MEA - MEASLES (NO BRAND NAME)' ||
        $drug_name eq 'MERCK & CO. INC. - MER - MEASLES + RUBELLA (MR-VAX II)' ||
        $drug_name eq 'MERCK & CO. INC. - MM - MEASLES + MUMPS (MM-VAX)' ||
        $drug_name eq 'MERCK & CO. INC. - MM - MEASLES + MUMPS (NO BRAND NAME)' ||
        $drug_name eq 'MERCK & CO. INC. - MMR - MEASLES + MUMPS + RUBELLA (MMR I)' ||
        $drug_name eq 'MERCK & CO. INC. - MMR - MEASLES + MUMPS + RUBELLA (VIRIVAC)' ||
        $drug_name eq 'MERCK & CO. INC. - MU - MUMPS (MUMPSVAX I)' ||
        $drug_name eq 'MERCK & CO. INC. - MU - MUMPS (MUMPSVAX II)' ||
        $drug_name eq 'MERCK & CO. INC. - MUR - MUMPS + RUBELLA (FOREIGN)' ||
        $drug_name eq 'MERCK & CO. INC. - PNC15 - PNEUMO (VAXNEUVANCE)' ||
        $drug_name eq 'MERCK & CO. INC. - RUB - RUBELLA (MERUVAX I)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLUA3 - INFLUENZA (SEASONAL) (CHIROMAS)' ||
        $drug_name eq 'BERNA BIOTECH, LTD. - MEA - MEASLES (MORATEN)' ||
        $drug_name eq 'PFIZER\WYETH - TBE - TICK-BORNE ENCEPH (TICOVAC)' ||
        $drug_name eq 'MEDEVA PHARMA, LTD. - FLUX - INFLUENZA (SEASONAL) (NO BRAND NAME)' ||
        $drug_name eq 'CSL LIMITED - FLU3 - INFLUENZA (SEASONAL) (ENZIRA)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU3 - INFLUENZA (SEASONAL) (TIV QUEBEC)' ||
        $drug_name eq 'CSL LIMITED - FLUX - INFLUENZA (SEASONAL) (FOREIGN)' ||
        $drug_name eq 'MERCK & CO. INC. - UNK - VACCINE NOT SPECIFIED (NO BRAND NAME)' ||
        $drug_name eq 'MICHIGAN DEPT PUB HLTH - ANTH - ANTHRAX (NO BRAND NAME)' ||
        $drug_name eq 'MICHIGAN DEPT PUB HLTH - RAB - RABIES (NO BRAND NAME)' ||
        $drug_name eq 'MILES LABORATORIES - PLAGUE - PLAGUE (NO BRAND NAME)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLU(H1N1) - INFLUENZA (H1N1) (H1N1 (MONOVALENT) (NOVARTIS))' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLU3 - INFLUENZA (SEASONAL) (AGRIFLU)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLU3 - INFLUENZA (SEASONAL) (FLUVIRIN)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLUC3 - INFLUENZA (SEASONAL) (OPTAFLU)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLUX - INFLUENZA (SEASONAL) (FOREIGN)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - RAB - RABIES (RABIVAC)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - RAB - RABIES (RABIPUR)' ||
        $drug_name eq 'ORGANON-TEKNIKA - BCG - BCG (TICE)' ||
        $drug_name eq 'PARKDALE PHARMACEUTICALS - FLU3 - INFLUENZA (SEASONAL) (FLUOGEN)' ||
        $drug_name eq 'PARKE-DAVIS - FLU3 - INFLUENZA (SEASONAL) (FLUOGEN)' ||
        $drug_name eq 'PASTEUR MERIEUX INST. - RAB - RABIES (IMOVAX ID)' ||
        $drug_name eq 'PASTEUR MERIEUX INST. - RAB - RABIES (IMOVAX)' ||
        $drug_name eq 'PFIZER\WYETH - ADEN - ADENOVIRUS (TYPE 4, NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - ADEN - ADENOVIRUS (TYPE 7, NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - CHOL - CHOLERA (USP)' ||
        $drug_name eq 'PFIZER\WYETH - FLU3 - INFLUENZA (SEASONAL) (FLU-IMUNE)' ||
        $drug_name eq 'PFIZER\WYETH - FLU3 - INFLUENZA (SEASONAL) (FLUSHIELD)' ||
        $drug_name eq 'PFIZER\WYETH - FLUX - INFLUENZA (SEASONAL) (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - HBPV - HIB POLYSACCHARIDE (HIBIMUNE)' ||
        $drug_name eq 'PFIZER\WYETH - HIBV - HIB (HIBTITER)' ||
        $drug_name eq 'PFIZER\WYETH - MNC - MENINGOCOCCAL (MENINGITEC)' ||
        $drug_name eq 'PFIZER\WYETH - PPV - PNEUMO (PNU-IMUNE)' ||
        $drug_name eq 'PFIZER\WYETH - RV - ROTAVIRUS (ROTASHIELD)' ||
        $drug_name eq 'PFIZER\WYETH - SMALL - SMALLPOX (DRYVAX)' ||
        $drug_name eq 'PFIZER\WYETH - TYP - TYPHOID VI POLYSACCHARIDE (ACETONE INACTIVATED DRIED)' ||
        $drug_name eq 'PFIZER\WYETH - TYP - TYPHOID VI POLYSACCHARIDE (NO BRAND NAME)' ||
        $drug_name eq 'PROTEIN SCIENCES CORPORATION - FLUR3 - INFLUENZA (SEASONAL) (FLUBLOK)' ||
        $drug_name eq 'SANOFI PASTEUR - DF - DENGUE TETRAVALENT (DENGVAXIA)' ||
        $drug_name eq 'SANOFI PASTEUR - FLU(H1N1) - INFLUENZA (H1N1) (H1N1 (MONOVALENT) (SANOFI))' ||
        $drug_name eq 'SANOFI PASTEUR - FLU3 - INFLUENZA (SEASONAL) (FLUZONE INTRADERMAL)' ||
        $drug_name eq 'SANOFI PASTEUR - FLU4 - INFLUENZA (SEASONAL) (FLUZONE INTRADERMAL QUADRIVALENT)' ||
        $drug_name eq 'SANOFI PASTEUR - H5N1 - INFLUENZA (SEASONAL) (PANDEMIC FLU VACCINE (H5N1))' ||
        $drug_name eq 'SANOFI PASTEUR - HIBV - HIB (OMNIHIB)' ||
        $drug_name eq 'SANOFI PASTEUR - HIBV - HIB (PROHIBIT)' ||
        $drug_name eq 'SANOFI PASTEUR - HIBV - HIB (TETRACOQ)' ||
        $drug_name eq 'SANOFI PASTEUR - JEV - JAPANESE ENCEPHALITIS (JE-VAX)' ||
        $drug_name eq 'SANOFI PASTEUR - RAB - RABIES (IMOVAX)' ||
        $drug_name eq 'SANOFI PASTEUR - RAB - RABIES (RABIE-VAX)' ||
        $drug_name eq 'SANOFI PASTEUR - RUB - RUBELLA (RUDIVAX)' ||
        $drug_name eq 'SANOFI PASTEUR - YF - YELLOW FEVER (STAMARIL)' ||
        $drug_name eq 'SMITHKLINE BEECHAM - HEPA - HEP A (HAVRIX)' ||
        $drug_name eq 'SMITHKLINE BEECHAM - LYME - LYME (LYMERIX)' ||
        $drug_name eq 'TEVA PHARMACEUTICALS - ADEN_4_7 - ADENOVIRUS TYPES 4 & 7, LIVE, ORAL (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - ADEN - ADENOVIRUS (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - ANTH - ANTHRAX (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - BCG - BCG (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - CEE - FSME-IMMUN. (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - CHOL - CHOLERA (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MEA - MEASLES (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MENHIB - MENINGOCOCCAL CONJUGATE + HIB (UNKNOWN)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MER - MEASLES + RUBELLA (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MM - MEASLES + MUMPS (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MMRV - MEASLES + MUMPS + RUBELLA + VARICELLA (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MNQ - MENINGOCOCCAL CONJUGATE (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MUR - MUMPS + RUBELLA (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - PER - PERTUSSIS (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - PLAGUE - PLAGUE (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - RAB - RABIES (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - SSEV - SUMMER/SPRING ENCEPH (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TBE - TICK-BORNE ENCEPH (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TYP - TYPHOID LIVE ORAL TY21A (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TYP - TYPHOID VI POLYSACCHARIDE (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - UNK - VACCINE NOT SPECIFIED (FOREIGN)' ||
        $drug_name eq 'GREER LABORATORIES, INC. - PLAGUE - PLAGUE (USP)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - JEVX - JAPANESE ENCEPHALITIS (NO BRAND NAME)' ||
        $drug_name eq 'LEDERLE LABORATORIES - CHOL - CHOLERA (USP)' ||
        $drug_name eq 'SANOFI PASTEUR - YF - YELLOW FEVER (YF-VAX)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - HPVX - HPV (NO BRAND NAME)' ||
        $drug_name eq 'MEDIMMUNE VACCINES, INC. - FLUN4 - INFLUENZA (SEASONAL) (FLUMIST QUADRIVALENT)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - RAB - RABIES (RABAVERT)' ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - FLUC3 - INFLUENZA (SEASONAL) (FLUCELVAX)' ||
        $drug_name eq 'BERNA BIOTECH, LTD. - TYP - TYPHOID LIVE ORAL TY21A (VIVOTIF)' ||
        $drug_name eq 'BURROUGHS WELLCOME - RUB - RUBELLA (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - VARCEL - VARICELLA (VARILRIX)' ||
        $drug_name eq 'INTERCELL AG - JEV1 - JAPANESE ENCEPHALITIS (IXIARO)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - FLUX(H1N1) - INFLUENZA (H1N1) (H1N1 (MONOVALENT) (UNKNOWN))' ||
        $drug_name eq 'MEDIMMUNE VACCINES, INC. - FLUN3 - INFLUENZA (SEASONAL) (FLUMIST)' ||
        $drug_name eq 'CONNAUGHT LTD. - RAB - RABIES (IMOVAX)' ||
        $drug_name eq 'SANOFI PASTEUR - FLUX - INFLUENZA (SEASONAL) (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - HEPA - HEP A (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - JEV - JAPANESE ENCEPHALITIS (J-VAX)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - HEPA - HEP A (HAVRIX)' ||
        $drug_name eq 'SANOFI PASTEUR - MNQ - MENINGOCOCCAL CONJUGATE (MENACTRA)' ||
        $drug_name eq 'CSL LIMITED - FLU(H1N1) - INFLUENZA (H1N1) (H1N1 (MONOVALENT) (CSL))' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - YF - YELLOW FEVER (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LTD. - MEN - MENINGOCOCCAL (MENOMUNE-A/C)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - MMR - MEASLES + MUMPS + RUBELLA (NO BRAND NAME)' ||
        $drug_name eq 'EMERGENT BIOSOLUTIONS - PER - PERTUSSIS (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - FLUX - INFLUENZA (SEASONAL) (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - MEN - MENINGOCOCCAL (MENOMUNE)' ||
        $drug_name eq 'SANOFI PASTEUR - MNQ - MENINGOCOCCAL CONJUGATE (MENQUADFI)' ||
        $drug_name eq 'EMERGENT BIOSOLUTIONS - RAB - RABIES (NO BRAND NAME)' ||
        $drug_name eq 'SEQIRUS, INC. - FLU4 - INFLUENZA (SEASONAL) (AFLURIA QUADRIVALENT)' ||
        $drug_name eq 'SANOFI PASTEUR - SMALL - SMALLPOX (ACAM2000)' ||
        $drug_name eq 'LEDERLE LABORATORIES - FLU3 - INFLUENZA (SEASONAL) (FLU-IMUNE)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - YF - YELLOW FEVER (YF-VAX)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - TYP - TYPHOID VI POLYSACCHARIDE (TYPHIM VI)' ||
        $drug_name eq 'EVANS VACCINES - FLU3 - INFLUENZA (SEASONAL) (FLUVIRIN)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - MEN - MENINGOCOCCAL (MENOMUNE)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - UNK - VACCINE NOT SPECIFIED (NO BRAND NAME)' ||
        $drug_name eq 'EMERGENT BIOSOLUTIONS - ANTH - ANTHRAX (BIOTHRAX)' ||
        $drug_name eq 'CSL LIMITED - FLU3 - INFLUENZA (SEASONAL) (AFLURIA)' ||
        $drug_name eq 'CSL LIMITED - FLU3 - INFLUENZA (SEASONAL) (FLUVAX)' ||
        $drug_name eq 'CSL LIMITED - FLU3 - INFLUENZA (SEASONAL) (NILGRIP)' ||
        $drug_name eq 'CSL LIMITED - FLU3 - INFLUENZA (SEASONAL) (FOREIGN)' ||
        $drug_name eq 'SANOFI PASTEUR - FLU4 - INFLUENZA (SEASONAL) (FLUZONE QUADRIVALENT)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - FLU4 - INFLUENZA (SEASONAL) (FLUARIX QUADRIVALENT)' ||
        $drug_name eq 'BAVARIAN NORDIC - SMALLMNK - SMALLPOX + MONKEYPOX (JYNNEOS)';
    my $drug_short_name;
    if (
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - HIBV - HIB (HIBERIX)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - HIBV - HIB (ACTHIB)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - HIBV - HIB (PROHIBIT)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - HBPV - HIB POLYSACCHARIDE (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - HEP - HEP B (GENHEVAC B)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - HEP - HEPBC (NO BRAND NAME)'
    ) {
        $drug_short_name = 'HEPATITE B VACCINE';
    } elsif (
        $drug_name eq 'SANOFI PASTEUR - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'SCLAVO - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'MICHIGAN DEPT PUB HLTH - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DT - DT ADSORBED (DITANRIX)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTOX - DIPHTHERIA TOXOIDS (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LTD. - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'BSI - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'LEDERLE LABORATORIES - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'EMERGENT BIOSOLUTIONS - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'MASS. PUB HLTH BIOL LAB - DT - DT ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - DT - DT ADSORBED (DECAVAC)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DT - DT ADSORBED (NO BRAND NAME)'
    ) {
        $drug_short_name = 'DIPHTHERIA VACCINE';
    } elsif (
        $drug_name eq 'PASTEUR MERIEUX CONNAUGHT - IPV - POLIO VIRUS, INACT. (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - IPV - POLIO VIRUS, INACT. (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - IPV - POLIO VIRUS, INACT. (IPOL)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - IPV - POLIO VIRUS, INACT. (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - IPV - POLIO VIRUS, INACT. (POLIOVAX)' ||
        $drug_name eq 'PASTEUR MERIEUX INST. - IPV - POLIO VIRUS, INACT. (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - OPV - POLIO VIRUS, ORAL (NO BRAND NAME)'
    ) {
        $drug_short_name = 'POLIOMYELITIS (IPV) VACCINE';
    } elsif (
        $drug_name eq 'UNKNOWN MANUFACTURER - OPV - POLIO VIRUS, ORAL (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - OPV - POLIO VIRUS, ORAL (ORIMUNE)' ||
        $drug_name eq 'CONNAUGHT LTD. - IPV - POLIO VIRUS, INACT. (POLIOVAX)'
    ) {
        $drug_short_name = 'POLIOMYELITIS (OPV) VACCINE';
    } elsif (
        $drug_name eq 'UNKNOWN MANUFACTURER - TTOX - TETANUS TOXOID (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'BERNA BIOTECH, LTD. - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - TTOX - TETANUS TOXOID (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - TTOX - TETANUS TOXOID (TEVAX)' ||
        $drug_name eq 'EMERGENT BIOSOLUTIONS - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'LEDERLE LABORATORIES - TTOX - TETANUS TOXOID (NO BRAND NAME)' ||
        $drug_name eq 'LEDERLE LABORATORIES - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'MASS. PUB HLTH BIOL LAB - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'MEDEVA PHARMA, LTD. - TTOX - TETANUS TOXOID (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - TD - TD ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - TTOX - TETANUS TOXOID (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'MICHIGAN DEPT PUB HLTH - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - TTOX - TETANUS TOXOID (NO BRAND NAME)' ||
        $drug_name eq 'SCLAVO - TTOX - TETANUS TOXOID (NO BRAND NAME)' ||
        $drug_name eq 'SCLAVO - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TTOX - TETANUS TOXOID, ADSORBED (NO BRAND NAME)'
    ) {
        $drug_short_name = 'TETANUS VACCINE';
    } elsif (
        $drug_name eq 'MERCK & CO. INC. - HBHEPB - HIB + HEP B (COMVAX)' ||
        $drug_name eq 'MERCK & CO. INC. - HEP - HEP B (FOREIGN)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - HBHEPB - HIB + HEP B (NO BRAND NAME)'
    ) {
        $drug_short_name = 'HAEMOPHILIUS B & HEPATITE B VACCINE';
    } elsif (
        $drug_name eq 'UNKNOWN MANUFACTURER - HEPAB - HEP A + HEP B (NO BRAND NAME)' ||
        $drug_name eq 'DYNAVAX TECHNOLOGIES CORPORATION - HEP - HEP B (HEPLISAV-B)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - HEP - HEP B (ENGERIX-B)' ||
        $drug_name eq 'MERCK & CO. INC. - HEP - HEP B (RECOMBIVAX HB)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - HEP - HEP B (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - HEPAB - HEP A + HEP B (TWINRIX)' ||
        $drug_name eq 'SMITHKLINE BEECHAM - HEP - HEP B (ENGERIX-B)' ||
        $drug_name eq 'SMITHKLINE BEECHAM - HEPAB - HEP A + HEP B (TWINRIX)'
    ) {
        $drug_short_name = 'HEPATITE A & HEPATITE B VACCINE';
    } elsif (
        $drug_name eq 'SANOFI PASTEUR - DTAPIPV - DTAP + IPV (QUADRACEL)' ||
        $drug_name eq 'SANOFI PASTEUR - DTPIPV - DTP + IPV (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DPIPV - DP + IPV (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTAPIPV - DTAP + IPV (UNKNOWN)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTPIPV - DTP + IPV (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTP - TD + PERTUSSIS (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - 6VAX-F - DTAP+IPV+HEPB+HIB (HEXAVAC)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTIPV - DT + IPV (NO BRAND NAME)' ||
        $drug_name eq 'PASTEUR MERIEUX INST. - DTIPV - DT + IPV (FOREIGN)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - DTAP - DTAP (TRIPEDIA)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTPHIB - DTP + HIB (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - DTAP - DTAP (ACEL-IMUNE)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - TDAPIPV - TDAP + IPV (FOREIGN)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TDAPIPV - TDAP + IPV (DOMESTIC)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DTAPIPV - DTAP + IPV (INFANRIX TETRA)'
    ) {
        $drug_short_name = 'DIPHTHERIA, TETANUS & POLIOMYELITIS VACCINE';
    } elsif (
        $drug_name eq 'MICHIGAN DEPT PUB HLTH - TD - TD ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - TDAP - TDAP (BOOSTRIX)' ||
        $drug_name eq 'SANOFI PASTEUR - TDAP - TDAP (ADACEL)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TDAP - TDAP (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TD - TD ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'MASS. PUB HLTH BIOL LAB - TD - TD ADSORBED (TDVAX)' ||
        $drug_name eq 'SANOFI PASTEUR - TD - TD ADSORBED (TENIVAC)' ||
        $drug_name eq 'SANOFI PASTEUR - TD - TD ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - TD - TD ADSORBED (TD-RIX)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - TD - TD ADSORBED (DITANRIX)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - TD - TETANUS DIPHTHERIA (NO BRAND NAME)' ||
        $drug_name eq 'LEDERLE LABORATORIES - TD - TD ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'AVENTIS PASTEUR - TD - TETANUS DIPHTHERIA (NO BRAND NAME)' ||
        $drug_name eq 'CONNAUGHT LABORATORIES - TD - TD ADSORBED (NO BRAND NAME)' ||
        $drug_name eq 'SCLAVO - TD - TD ADSORBED (NO BRAND NAME)'
    ) {
        $drug_short_name = 'DIPHTHERIA & TETANUS VACCINE';
    } elsif (
        $drug_name eq 'SMITHKLINE BEECHAM - DTAP - DTAP (INFANRIX)'                                                    ||
        $drug_name eq 'SANOFI PASTEUR - DTAP - DTAP (DAPTACEL)'                                                        ||
        $drug_name eq 'NORTH AMERICAN VACCINES - DTAP - DTAP (CERTIVA)'                                                ||
        $drug_name eq 'LEDERLE LABORATORIES - DTP - DTP (TRI-IMMUNOL)'                                                 ||
        $drug_name eq 'PFIZER\WYETH - DTP - DTP (NO BRAND NAME)'                                                       ||
        $drug_name eq 'MICHIGAN DEPT PUB HLTH - DTP - DTP (NO BRAND NAME)'                                             ||
        $drug_name eq 'SANOFI PASTEUR - DTP - DTP (NO BRAND NAME)'                                                     ||
        $drug_name eq 'NOVARTIS VACCINES AND DIAGNOSTICS - DPP - DIPHTHERIA TOXOID + PERTUSSIS + IPV (QUATRO VIRELON)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DPP - DIPHTHERIA TOXOID + PERTUSSIS + IPV (NO BRAND NAME)'               ||
        $drug_name eq 'MASS. PUB HLTH BIOL LAB - DTP - DTP (NO BRAND NAME)'                                            ||
        $drug_name eq 'CONNAUGHT LABORATORIES - DTP - DTP (NO BRAND NAME)'                                             ||
        $drug_name eq 'BAXTER HEALTHCARE CORP. - DTAP - DTAP (CERTIVA)'                                                ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTAP - DTAP (NO BRAND NAME)'                                             ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DTAP - DTAP (INFANRIX)'                                           ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTP - DTP (NO BRAND NAME)'                                               ||
        $drug_name eq 'EMERGENT BIOSOLUTIONS - DTP - DTP (NO BRAND NAME)'                                              ||
        $drug_name eq 'SANOFI PASTEUR - DTAP - DTAP (TRIPEDIA)'
    ) {
        $drug_short_name = 'DIPHTERIA, TETANUS & PERTUSSIS VACCINE';
    } elsif (
        $drug_name eq 'SANOFI PASTEUR - DTAPIPVHIB - DTAP + IPV + HIB (PENTACEL)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTPIHI - DT+IPV+HIB+HEPB (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - 6VAX-F - DTAP+IPV+HEPB+HIB (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DTAPHEPBIP - DTAP + HEPB + IPV (INFANRIX PENTA)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DTAPHEPBIP - DTAP + HEPB + IPV (PEDIARIX)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DTAPIPV - DTAP + IPV (KINRIX)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTAPH - DTAP + HIB (NO BRAND NAME)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTAPIPVHIB - DTAP + IPV + HIB (UNKNOWN)' ||
        $drug_name eq 'MSP VACCINE COMPANY - DTPPVHBHPB - DTAP+IPV+HIB+HEPB (VAXELIS)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTAPHEPBIP - DTAP + HEPB + IPV (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - DTAPH - DTAP + HIB (TRIHIBIT)' ||
        $drug_name eq 'UNKNOWN MANUFACTURER - DTPPHIB - DTP + IPV + ACT-HIB (NO BRAND NAME)' ||
        $drug_name eq 'SANOFI PASTEUR - DTAPIPVHIB - DTAP + IPV + HIB (NO BRAND NAME)' ||
        $drug_name eq 'BERNA BIOTECH, LTD. - DTPIPV - DTP + IPV (NO BRAND NAME)' ||
        $drug_name eq 'PFIZER\WYETH - DTPHIB - DTP + HIB (TETRAMUNE)' ||
        $drug_name eq 'SANOFI PASTEUR - DTPHIB - DTP + HIB (DTP + ACTHIB)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DTAPIPVHIB - DTAP + IPV + HIB (INFANRIX QUINTA)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - 6VAX-F - DTAP+IPV+HEPB+HIB (INFANRIX HEXA)'
    ) {
        $drug_short_name = 'DIPHTERIA, TETANUS, WHOOPING COUGH, POLIOMYELITIS & HAEMOPHILIUS INFLUENZA TYPE B VACCINE';
    } elsif (
        $drug_name eq 'UNKNOWN MANUFACTURER - DTPHEP - DTP + HEP B (NO BRAND NAME)' ||
        $drug_name eq 'GLAXOSMITHKLINE BIOLOGICALS - DTPHEP - DTP + HEP B (TRITANRIX)'
    ) {
        $drug_short_name = 'DIPHTHERIA, TETANUS, PERTUSSIS & HEPATITIS B (RDNA) VACCINE';
    } elsif (
        $drug_name eq 'JANSSEN - COVID19 - COVID19 (COVID19 (JANSSEN))'
    ) {
        $drug_short_name = 'COVID-19 VACCINE JANSSEN';
    } elsif (
        $drug_name eq 'MODERNA - COVID19 - COVID19 (COVID19 (MODERNA))'
    ) {
        $drug_short_name = 'COVID-19 VACCINE MODERNA';
    } elsif (
        $drug_name eq 'PFIZER\BIONTECH - COVID19 - COVID19 (COVID19 (PFIZER-BIONTECH))'
    ) {
        $drug_short_name = 'COVID-19 VACCINE PFIZER-BIONTECH';
    } elsif ($drug_name eq 'UNKNOWN MANUFACTURER - COVID19 - COVID19 (COVID19 (UNKNOWN))') {
        $drug_short_name = 'COVID-19 VACCINE UNKNOWN MANUFACTURER';
    } elsif ($drug_name eq 'NOVAVAX - COVID19 - COVID19 (COVID19 (NOVAVAX))') {
        $drug_short_name = 'COVID-19 VACCINE NOVAVAX';
    } else {
    	$drug_short_name = $drug_name;
        # die "unknown : drug_name : $drug_name";
    }
    my $drug_category;
    if ($drug_short_name =~ /COVID-19/) {
        $drug_category = 'COVID-19';
    } else {
        $drug_category = 'OTHER'
    }
    return ($drug_category, $drug_short_name);
}