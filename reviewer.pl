#!/usr/bin/perl
use strict;
use warnings;
use 5.30.0;
no autovivification;
use utf8;

use Mojolicious::Lite -signatures;
use JSON;
use Scalar::Util qw(looks_like_number);
use POSIX qw(strftime);


# ================================================================
#  CONFIG
# ================================================================

my $ARCHIVE_FILE        = 'data_archive.json';
my $AGES_CSV            = 'age_from_text_ollama.csv';
my $OUTCOMES_CSV        = 'outcomes_minors_ollama.csv';
my $AGE_REVIEWS_FILE    = 'age_reviews.json';
my $SEV_REVIEWS_FILE    = 'severity_reviews.json';
my $PER_PAGE            = 50;

# ================================================================
#  DATA LOADING
# ================================================================

my %archive   = ();
my @ages      = ();   # array of hashrefs
my %ages_idx  = ();   # vaers_id => index in @ages
my @ages_found     = ();   # subset: only status=ok
my %ages_found_idx = ();   # vaers_id => index in @ages_found
my @outcomes  = ();
my %outc_idx  = ();

my %age_reviews = ();
my %sev_reviews = ();

sub load_archive {
    app->log->info("Loading archive from $ARCHIVE_FILE ...");
    open my $in, '<', $ARCHIVE_FILE or die "Cannot open $ARCHIVE_FILE: $!";
    my $json;
    while (<$in>) {
        $json .= $_;
    }
    close $in;
    my $data = decode_json($json);
    %archive = %$data;
    app->log->info("  Archive records: " . scalar(keys %archive));
}

sub load_ages_csv {
    app->log->info("Loading ages CSV from $AGES_CSV ...");
    @ages     = ();
    %ages_idx = ();
    open my $fh, '<:utf8', $AGES_CSV or do {
        app->log->warn("Cannot open $AGES_CSV: $!");
        return;
    };
    my $header = <$fh>;
    my $i = 0;
    while (<$fh>) {
        chomp;
        next unless length $_;
        my ($vaers_id, $age, $status, $evidence) = split /;/, $_, 4;
        next unless defined $vaers_id && length $vaers_id;
        push @ages, {
            vaers_id => $vaers_id,
            age      => $age // 'null',
            status   => $status // '',
            evidence => $evidence // '',
        };
        $ages_idx{$vaers_id} = $i;
        $i++;
    }
    close $fh;
    app->log->info("  Ages rows: " . scalar(@ages));

    # Build the "found" subset (status=ok only)
    @ages_found     = ();
    %ages_found_idx = ();
    my $fi = 0;
    for my $rec (@ages) {
        next unless ($rec->{status} // '') eq 'ok';
        push @ages_found, $rec;
        $ages_found_idx{ $rec->{vaers_id} } = $fi;
        $fi++;
    }
    app->log->info("  Ages found (status=ok): " . scalar(@ages_found));
}

sub load_outcomes_csv {
    app->log->info("Loading outcomes CSV from $OUTCOMES_CSV ...");
    @outcomes = ();
    %outc_idx = ();
    open my $fh, '<:utf8', $OUTCOMES_CSV or do {
        app->log->warn("Cannot open $OUTCOMES_CSV: $!");
        return;
    };
    my $header = <$fh>;
    my $i = 0;
    while (<$fh>) {
        chomp;
        next unless length $_;
        my ($vaers_id, $age, $lt, $died, $disab, $status, $evidence) = split /;/, $_, 7;
        next unless defined $vaers_id && length $vaers_id;
        push @outcomes, {
            vaers_id         => $vaers_id,
            age              => $age // 'null',
            life_threatening => $lt // '',
            subject_died     => $died // '',
            disability       => $disab // '',
            status           => $status // '',
            evidence         => $evidence // '',
        };
        $outc_idx{$vaers_id} = $i;
        $i++;
    }
    close $fh;
    app->log->info("  Outcomes rows: " . scalar(@outcomes));
}

sub load_reviews {
    if (-f $AGE_REVIEWS_FILE) {
        open my $in, '<', $AGE_REVIEWS_FILE or die "Cannot open $AGE_REVIEWS_FILE: $!";
        my $raw;
        while (<$in>) { $raw .= $_ }
        close $in;
        my $data = eval { decode_json($raw) };
        %age_reviews = %$data if $data;
        app->log->info("  Age reviews loaded: " . scalar(keys %age_reviews));
    }
    if (-f $SEV_REVIEWS_FILE) {
        open my $in, '<', $SEV_REVIEWS_FILE or die "Cannot open $SEV_REVIEWS_FILE: $!";
        my $raw;
        while (<$in>) { $raw .= $_ }
        close $in;
        my $data = eval { decode_json($raw) };
        %sev_reviews = %$data if $data;
        app->log->info("  Severity reviews loaded: " . scalar(keys %sev_reviews));
    }
}

sub save_age_reviews {
    open my $out, '>', $AGE_REVIEWS_FILE or die "Cannot write $AGE_REVIEWS_FILE: $!";
    print $out encode_json(\%age_reviews);
    close $out;
}

sub save_sev_reviews {
    open my $out, '>', $SEV_REVIEWS_FILE or die "Cannot write $SEV_REVIEWS_FILE: $!";
    print $out encode_json(\%sev_reviews);
    close $out;
}

# ================================================================
#  HELPERS
# ================================================================

helper archive_record => sub ($c, $vaers_id) {
    return $archive{$vaers_id} // {};
};

helper age_review_stats => sub ($c) {
    my $total     = scalar @ages;
    my $reviewed  = scalar keys %age_reviews;
    my $validated = 0;
    my $corrected = 0;
    my $rejected  = 0;
    for my $r (values %age_reviews) {
        my $d = $r->{decision} // '';
        $validated++ if $d eq 'validated';
        $corrected++ if $d eq 'corrected';
        $rejected++  if $d eq 'rejected';
    }
    return {
        total     => $total,
        reviewed  => $reviewed,
        validated => $validated,
        corrected => $corrected,
        rejected  => $rejected,
        pending   => $total - $reviewed,
        pct       => $total > 0 ? sprintf("%.1f", $reviewed / $total * 100) : '0.0',
    };
};

helper age_found_stats => sub ($c) {
    my $total     = scalar @ages_found;
    my $reviewed  = 0;
    my $validated = 0;
    my $corrected = 0;
    my $rejected  = 0;
    for my $rec (@ages_found) {
        my $r = $age_reviews{ $rec->{vaers_id} };
        next unless $r;
        $reviewed++;
        my $d = $r->{decision} // '';
        $validated++ if $d eq 'validated';
        $corrected++ if $d eq 'corrected';
        $rejected++  if $d eq 'rejected';
    }
    return {
        total     => $total,
        reviewed  => $reviewed,
        validated => $validated,
        corrected => $corrected,
        rejected  => $rejected,
        pending   => $total - $reviewed,
        pct       => $total > 0 ? sprintf("%.1f", $reviewed / $total * 100) : '0.0',
    };
};

helper sev_review_stats => sub ($c) {
    my $total     = scalar @outcomes;
    my $reviewed  = scalar keys %sev_reviews;
    my $validated = 0;
    my $corrected = 0;
    my $excluded  = 0;
    my $child_deaths   = 0;
    my $subject_deaths = 0;
    for my $r (values %sev_reviews) {
        my $d  = $r->{decision} // '';
        $validated++ if $d eq 'validated';
        $corrected++ if $d eq 'corrected';
        $excluded++  if $d eq 'excluded';
        my $dt = $r->{death_type} // '';
        $child_deaths++   if $dt eq 'child';
        $subject_deaths++ if $dt eq 'subject';
    }
    return {
        total          => $total,
        reviewed       => $reviewed,
        validated      => $validated,
        corrected      => $corrected,
        excluded       => $excluded,
        pending        => $total - $reviewed,
        pct            => $total > 0 ? sprintf("%.1f", $reviewed / $total * 100) : '0.0',
        child_deaths   => $child_deaths,
        subject_deaths => $subject_deaths,
    };
};

helper highlight_age_in_text => sub ($c, $text, $age) {
    return $text unless defined $age && $age ne 'null' && $age ne '';
    # Highlight mentions of the age in the text (approximate)
    my $escaped = quotemeta($age);
    $text =~ s/\b($escaped)\s*(year|yr|y\.?o\.?|month|mo|week|wk|day|old)/
        '<mark class="age-hl">' . $1 . ' ' . $2 . '<\/mark>'/gei;
    # Also highlight bare age mentions like "age: 5" or "5 year old"
    $text =~ s/\b(age\s*[:=]?\s*)($escaped)\b/
        $1 . '<mark class="age-hl">' . $2 . '<\/mark>'/gei;
    return $text;
};

# ================================================================
#  STARTUP
# ================================================================

load_archive();
load_ages_csv();
load_outcomes_csv();
load_reviews();

# ================================================================
#  ROUTES
# ================================================================

# ---- Dashboard ----
get '/' => sub ($c) {
    $c->stash(
        age_stats       => $c->age_review_stats,
        age_found_stats => $c->age_found_stats,
        sev_stats       => $c->sev_review_stats,
    );
    $c->render(template => 'dashboard');
};

# ---- Ages list ----
get '/ages' => sub ($c) {
    my $filter = $c->param('filter') // 'all';    # all | pending | reviewed | ok | ambiguous | missing | error
    my $page   = int($c->param('page') // 1);
    $page = 1 if $page < 1;

    my @filtered;
    for my $rec (@ages) {
        my $vid = $rec->{vaers_id};
        my $is_reviewed = exists $age_reviews{$vid};
        if ($filter eq 'pending') {
            next if $is_reviewed;
        } elsif ($filter eq 'reviewed') {
            next unless $is_reviewed;
        } elsif ($filter =~ /^(ok|ambiguous|missing|error)$/) {
            next unless ($rec->{status} // '') eq $filter;
        }
        push @filtered, $rec;
    }

    my $total_filtered = scalar @filtered;
    my $total_pages    = int(($total_filtered + $PER_PAGE - 1) / $PER_PAGE) || 1;
    $page = $total_pages if $page > $total_pages;
    my $offset = ($page - 1) * $PER_PAGE;
    my @page_items = @filtered[$offset .. min($offset + $PER_PAGE - 1, $#filtered)];

    $c->stash(
        items      => \@page_items,
        filter     => $filter,
        page       => $page,
        total_pages => $total_pages,
        total_items => $total_filtered,
        reviews    => \%age_reviews,
        stats      => $c->age_review_stats,
    );
    $c->render(template => 'ages_list');
};

# ---- Ages found list (status=ok only) ----
get '/ages/found' => sub ($c) {
    my $filter = $c->param('filter') // 'all';    # all | pending | reviewed
    my $page   = int($c->param('page') // 1);
    $page = 1 if $page < 1;

    my @filtered;
    for my $rec (@ages_found) {
        my $vid = $rec->{vaers_id};
        my $is_reviewed = exists $age_reviews{$vid};
        if ($filter eq 'pending') {
            next if $is_reviewed;
        } elsif ($filter eq 'reviewed') {
            next unless $is_reviewed;
        }
        push @filtered, $rec;
    }

    my $total_filtered = scalar @filtered;
    my $total_pages    = int(($total_filtered + $PER_PAGE - 1) / $PER_PAGE) || 1;
    $page = $total_pages if $page > $total_pages;
    my $offset = ($page - 1) * $PER_PAGE;
    my @page_items = @filtered[$offset .. min($offset + $PER_PAGE - 1, $#filtered)];

    $c->stash(
        items       => \@page_items,
        filter      => $filter,
        page        => $page,
        total_pages => $total_pages,
        total_items => $total_filtered,
        reviews     => \%age_reviews,
        stats       => $c->age_found_stats,
    );
    $c->render(template => 'ages_found_list');
};

# ---- Age review (single record) ----
get '/ages/review/:vaers_id' => sub ($c) {
    my $vid  = $c->param('vaers_id');
    my $from = $c->param('from') // 'all';   # 'found' or 'all'
    my $idx  = $ages_idx{$vid};
    unless (defined $idx) {
        return $c->reply->not_found;
    }

    my $rec     = $ages[$idx];
    my $archive = $c->archive_record($vid);
    my $review  = $age_reviews{$vid};

    # Pick the right pool for "next unreviewed"
    my ($pool_ref, $pool_idx_ref) = ($from eq 'found')
        ? (\@ages_found, \%ages_found_idx)
        : (\@ages,       \%ages_idx);

    my $pool_pos = $pool_idx_ref->{$vid};   # position in pool
    my $next_unreviewed = undef;

    if (defined $pool_pos) {
        # Forward scan
        for my $i ($pool_pos + 1 .. $#$pool_ref) {
            unless (exists $age_reviews{ $pool_ref->[$i]->{vaers_id} }) {
                $next_unreviewed = $pool_ref->[$i]->{vaers_id};
                last;
            }
        }
        # Wrap around
        if (!$next_unreviewed) {
            for my $i (0 .. $pool_pos - 1) {
                unless (exists $age_reviews{ $pool_ref->[$i]->{vaers_id} }) {
                    $next_unreviewed = $pool_ref->[$i]->{vaers_id};
                    last;
                }
            }
        }
    }

    my $stats = ($from eq 'found') ? $c->age_found_stats : $c->age_review_stats;

    $c->stash(
        rec             => $rec,
        archive         => $archive,
        review          => $review,
        next_unreviewed => $next_unreviewed,
        stats           => $stats,
        from            => $from,
    );
    $c->render(template => 'age_review');
};

# ---- Save age review ----
post '/ages/review/:vaers_id' => sub ($c) {
    my $vid      = $c->param('vaers_id');
    my $from     = $c->param('from') // 'all';
    my $decision = $c->param('decision') // '';
    my $corr_age = $c->param('corrected_age') // '';
    my $notes    = $c->param('notes') // '';

    my %entry = (
        decision     => $decision,
        notes        => $notes,
        reviewed_at  => strftime("%Y-%m-%dT%H:%M:%S", localtime),
    );

    if ($decision eq 'corrected' && looks_like_number($corr_age)) {
        $entry{corrected_age} = $corr_age + 0;
    }

    $age_reviews{$vid} = \%entry;
    save_age_reviews();

    # Redirect to next unreviewed or back to list
    my $next = $c->param('next_unreviewed') // '';
    if ($next && $next ne '' && exists $ages_idx{$next}) {
        return $c->redirect_to("/ages/review/$next?from=$from");
    }
    my $back = ($from eq 'found') ? '/ages/found?filter=pending' : '/ages?filter=pending';
    $c->redirect_to($back);
};

# ---- Severity list ----
get '/severity' => sub ($c) {
    my $filter = $c->param('filter') // 'all';
    my $page   = int($c->param('page') // 1);
    $page = 1 if $page < 1;

    my @filtered;
    for my $rec (@outcomes) {
        my $vid = $rec->{vaers_id};
        my $is_reviewed = exists $sev_reviews{$vid};
        if ($filter eq 'pending') {
            next if $is_reviewed;
        } elsif ($filter eq 'reviewed') {
            next unless $is_reviewed;
        } elsif ($filter eq 'deaths') {
            next unless ($rec->{subject_died} // '') eq 'yes';
        } elsif ($filter eq 'severe') {
            next unless (($rec->{life_threatening} // '') eq 'yes'
                      || ($rec->{subject_died} // '') eq 'yes'
                      || ($rec->{disability} // '') eq 'yes');
        }
        push @filtered, $rec;
    }

    my $total_filtered = scalar @filtered;
    my $total_pages    = int(($total_filtered + $PER_PAGE - 1) / $PER_PAGE) || 1;
    $page = $total_pages if $page > $total_pages;
    my $offset = ($page - 1) * $PER_PAGE;
    my @page_items = @filtered[$offset .. min($offset + $PER_PAGE - 1, $#filtered)];

    $c->stash(
        items       => \@page_items,
        filter      => $filter,
        page        => $page,
        total_pages => $total_pages,
        total_items => $total_filtered,
        reviews     => \%sev_reviews,
        stats       => $c->sev_review_stats,
    );
    $c->render(template => 'severity_list');
};

# ---- Severity review (single record) ----
get '/severity/review/:vaers_id' => sub ($c) {
    my $vid = $c->param('vaers_id');
    my $idx = $outc_idx{$vid};
    unless (defined $idx) {
        return $c->reply->not_found;
    }

    my $rec     = $outcomes[$idx];
    my $archive = $c->archive_record($vid);
    my $review  = $sev_reviews{$vid};

    # Find next unreviewed
    my $next_unreviewed = undef;
    for my $i ($idx + 1 .. $#outcomes) {
        unless (exists $sev_reviews{ $outcomes[$i]->{vaers_id} }) {
            $next_unreviewed = $outcomes[$i]->{vaers_id};
            last;
        }
    }
    if (!$next_unreviewed) {
        for my $i (0 .. $idx - 1) {
            unless (exists $sev_reviews{ $outcomes[$i]->{vaers_id} }) {
                $next_unreviewed = $outcomes[$i]->{vaers_id};
                last;
            }
        }
    }

    $c->stash(
        rec             => $rec,
        archive         => $archive,
        review          => $review,
        next_unreviewed => $next_unreviewed,
        stats           => $c->sev_review_stats,
    );
    $c->render(template => 'severity_review');
};

# ---- Save severity review ----
post '/severity/review/:vaers_id' => sub ($c) {
    my $vid = $c->param('vaers_id');

    my %entry = (
        decision          => $c->param('decision') // '',
        death_type        => $c->param('death_type') // '',
        cause_of_death    => $c->param('cause_of_death') // '',
        lt_override       => $c->param('lt_override') // '',
        disability_override => $c->param('disability_override') // '',
        notes             => $c->param('notes') // '',
        reviewed_at       => strftime("%Y-%m-%dT%H:%M:%S", localtime),
    );

    $sev_reviews{$vid} = \%entry;
    save_sev_reviews();

    my $next = $c->param('next_unreviewed') // '';
    if ($next && $next ne '' && exists $outc_idx{$next}) {
        return $c->redirect_to("/severity/review/$next");
    }
    $c->redirect_to('/severity?filter=pending');
};

# ---- API: stats (for AJAX refresh) ----
get '/api/stats' => sub ($c) {
    $c->render(json => {
        ages     => $c->age_review_stats,
        severity => $c->sev_review_stats,
    });
};

# ---- API: export reviews as CSV ----
get '/api/export/ages' => sub ($c) {
    my $csv = "vaers_id;original_age;original_status;decision;corrected_age;notes;reviewed_at\n";
    for my $vid (sort { $a <=> $b } keys %age_reviews) {
        my $r   = $age_reviews{$vid};
        my $idx = $ages_idx{$vid};
        my $orig_age    = defined $idx ? ($ages[$idx]->{age} // 'null') : 'null';
        my $orig_status = defined $idx ? ($ages[$idx]->{status} // '') : '';
        my $corr        = $r->{corrected_age} // '';
        my $notes       = $r->{notes} // '';
        $notes =~ s/;/,/g;
        $notes =~ s/[\r\n]+/ /g;
        $csv .= join(';',
            $vid, $orig_age, $orig_status,
            $r->{decision} // '', $corr, $notes, $r->{reviewed_at} // ''
        ) . "\n";
    }
    $c->res->headers->content_disposition('attachment; filename="age_reviews_export.csv"');
    $c->render(data => $csv, format => 'csv');
};

get '/api/export/severity' => sub ($c) {
    my $csv = "vaers_id;age;orig_lt;orig_died;orig_disability;decision;death_type;cause_of_death;lt_override;disability_override;notes;reviewed_at\n";
    for my $vid (sort { $a <=> $b } keys %sev_reviews) {
        my $r   = $sev_reviews{$vid};
        my $idx = $outc_idx{$vid};
        my $orig = defined $idx ? $outcomes[$idx] : {};
        my $notes = $r->{notes} // '';
        $notes =~ s/;/,/g;
        $notes =~ s/[\r\n]+/ /g;
        my $cod = $r->{cause_of_death} // '';
        $cod =~ s/;/,/g;
        $cod =~ s/[\r\n]+/ /g;
        $csv .= join(';',
            $vid,
            $orig->{age} // 'null',
            $orig->{life_threatening} // '',
            $orig->{subject_died} // '',
            $orig->{disability} // '',
            $r->{decision} // '',
            $r->{death_type} // '',
            $cod,
            $r->{lt_override} // '',
            $r->{disability_override} // '',
            $notes,
            $r->{reviewed_at} // '',
        ) . "\n";
    }
    $c->res->headers->content_disposition('attachment; filename="severity_reviews_export.csv"');
    $c->render(data => $csv, format => 'csv');
};

# ---- min() helper ----
sub min { $_[0] < $_[1] ? $_[0] : $_[1] }

# ================================================================
app->start;

__DATA__

@@ layouts/default.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><%= title %> — VAERS Reviewer</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css"
        rel="stylesheet">
  <style>
    :root {
      --bs-font-sans-serif: 'Segoe UI', system-ui, -apple-system, sans-serif;
    }
    body { background: #f4f6f9; }
    .navbar { background: #1B2A4A !important; }
    .navbar-brand, .nav-link { color: #fff !important; }
    .nav-link:hover { color: #a8dadc !important; }
    .nav-link.active { font-weight: 600; border-bottom: 2px solid #a8dadc; }

    .stat-card {
      background: #fff; border-radius: 10px; padding: 1.2rem;
      box-shadow: 0 1px 4px rgba(0,0,0,.08);
    }
    .stat-card h6 { color: #666; font-size: .8rem; text-transform: uppercase; letter-spacing: .5px; }
    .stat-card .big { font-size: 1.8rem; font-weight: 700; }

    .progress-ring { height: 8px; border-radius: 4px; }

    .symptom-box {
      background: #fff; border: 1px solid #dee2e6; border-radius: 8px;
      padding: 1rem 1.2rem; max-height: 420px; overflow-y: auto;
      font-size: .88rem; line-height: 1.65; white-space: pre-wrap;
      word-break: break-word;
    }
    mark.age-hl { background: #fff3cd; padding: 1px 3px; border-radius: 3px; }
    mark.death-hl { background: #f8d7da; padding: 1px 3px; border-radius: 3px; }

    .llm-card {
      background: #eef6ff; border: 1px solid #b8d4f0; border-radius: 8px;
      padding: 1rem 1.2rem;
    }

    .review-form { background: #fff; border-radius: 10px; padding: 1.4rem; box-shadow: 0 1px 4px rgba(0,0,0,.08); }

    .badge-validated { background: #198754; }
    .badge-corrected { background: #0d6efd; }
    .badge-rejected  { background: #dc3545; }
    .badge-excluded  { background: #6c757d; }
    .badge-pending   { background: #ffc107; color: #333; }

    .table-sm td, .table-sm th { padding: .35rem .5rem; font-size: .85rem; }

    kbd { background: #333; color: #fff; padding: 2px 6px; border-radius: 3px; font-size: .78rem; }

    .filter-bar a { margin-right: .3rem; }
    .filter-bar a.active { font-weight: 700; }
  </style>
</head>
<body>

<nav class="navbar navbar-expand-lg mb-3">
  <div class="container-fluid">
    <a class="navbar-brand fw-bold" href="/">VAERS Reviewer</a>
    <div class="navbar-nav flex-row gap-3">
      <a class="nav-link <%= 'active' if (current_route() // '') =~ /^ages_found/ %>" href="/ages/found">Ages Found</a>
      <a class="nav-link <%= 'active' if (current_route() // '') =~ /^ages/ && (current_route() // '') !~ /found/ %>" href="/ages">Ages (all)</a>
      <a class="nav-link <%= 'active' if (current_route() // '') =~ /^sev/ %>" href="/severity">Severity</a>
      <a class="nav-link" href="/">Dashboard</a>
    </div>
  </div>
</nav>

<div class="container-fluid px-4">
  <%= content %>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>


@@ dashboard.html.ep
% layout 'default';
% title 'Dashboard';

<h4 class="mb-4">Review Dashboard</h4>

<!-- ============ Ages Found (status=ok) ============ -->
<div class="row g-3 mb-4">
  <div class="col-12">
    <h5>Ages Found — Validation <small class="text-muted">(LLM recovered an age, status=ok)</small></h5>
  </div>

  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Total found</h6>
      <div class="big"><%= $age_found_stats->{total} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Reviewed</h6>
      <div class="big text-primary"><%= $age_found_stats->{reviewed} %></div>
      <small class="text-muted"><%= $age_found_stats->{pct} %>%</small>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Validated</h6>
      <div class="big text-success"><%= $age_found_stats->{validated} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Corrected</h6>
      <div class="big text-info"><%= $age_found_stats->{corrected} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Rejected</h6>
      <div class="big text-danger"><%= $age_found_stats->{rejected} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Pending</h6>
      <div class="big text-warning"><%= $age_found_stats->{pending} %></div>
    </div>
  </div>

  <div class="col-12">
    <div class="progress progress-ring">
      <div class="progress-bar bg-success" style="width: <%= $age_found_stats->{pct} %>%"></div>
    </div>
  </div>

  <div class="col-12 mt-2">
    <a href="/ages/found?filter=pending" class="btn btn-primary btn-sm me-2">Review pending found ages</a>
    <a href="/api/export/ages" class="btn btn-outline-secondary btn-sm">Export age reviews CSV</a>
  </div>
</div>

<hr>

<!-- ============ Ages Overall ============ -->
<div class="row g-3 mb-4">
  <div class="col-12">
    <h5>Ages — Full Overview <small class="text-muted">(all statuses: ok / ambiguous / missing / error)</small></h5>
  </div>

  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Total</h6>
      <div class="big"><%= $age_stats->{total} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Reviewed</h6>
      <div class="big text-primary"><%= $age_stats->{reviewed} %></div>
      <small class="text-muted"><%= $age_stats->{pct} %>%</small>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Validated</h6>
      <div class="big text-success"><%= $age_stats->{validated} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Corrected</h6>
      <div class="big text-info"><%= $age_stats->{corrected} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Rejected</h6>
      <div class="big text-danger"><%= $age_stats->{rejected} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Pending</h6>
      <div class="big text-warning"><%= $age_stats->{pending} %></div>
    </div>
  </div>

  <div class="col-12">
    <div class="progress progress-ring">
      <div class="progress-bar bg-success" style="width: <%= $age_stats->{pct} %>%"></div>
    </div>
  </div>

  <div class="col-12 mt-2">
    <a href="/ages?filter=pending" class="btn btn-outline-primary btn-sm me-2">Review all pending ages</a>
  </div>
</div>

<hr>

<div class="row g-3 mb-4">
  <!-- Severity Review Stats -->
  <div class="col-12">
    <h5>Severity Classification Review (Minors)</h5>
  </div>

  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Total</h6>
      <div class="big"><%= $sev_stats->{total} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Reviewed</h6>
      <div class="big text-primary"><%= $sev_stats->{reviewed} %></div>
      <small class="text-muted"><%= $sev_stats->{pct} %>%</small>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Validated</h6>
      <div class="big text-success"><%= $sev_stats->{validated} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Excluded</h6>
      <div class="big text-secondary"><%= $sev_stats->{excluded} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Child deaths</h6>
      <div class="big text-danger"><%= $sev_stats->{child_deaths} %></div>
    </div>
  </div>
  <div class="col-md-2">
    <div class="stat-card text-center">
      <h6>Subject deaths</h6>
      <div class="big" style="color:#9B2335"><%= $sev_stats->{subject_deaths} %></div>
    </div>
  </div>

  <div class="col-12">
    <div class="progress progress-ring">
      <div class="progress-bar bg-danger" style="width: <%= $sev_stats->{pct} %>%"></div>
    </div>
  </div>

  <div class="col-12 mt-2">
    <a href="/severity?filter=pending" class="btn btn-danger btn-sm me-2">Review pending severity</a>
    <a href="/severity?filter=deaths" class="btn btn-outline-danger btn-sm me-2">Review deaths only</a>
    <a href="/api/export/severity" class="btn btn-outline-secondary btn-sm">Export severity reviews CSV</a>
  </div>
</div>


@@ ages_list.html.ep
% layout 'default';
% title 'Age Review';

<div class="d-flex justify-content-between align-items-center mb-3">
  <h4 class="mb-0">Age Extraction Review</h4>
  <div>
    <span class="badge bg-primary"><%= $stats->{reviewed} %> / <%= $stats->{total} %> reviewed (<%= $stats->{pct} %>%)</span>
  </div>
</div>

<!-- Filters -->
<div class="filter-bar mb-3">
  % my @filters = (
  %   ['all',       'All'],
  %   ['pending',   'Pending'],
  %   ['reviewed',  'Reviewed'],
  %   ['ok',        'Status: ok'],
  %   ['ambiguous', 'Status: ambiguous'],
  %   ['missing',   'Status: missing'],
  %   ['error',     'Status: error'],
  % );
  % for my $f (@filters) {
    <a href="/ages?filter=<%= $f->[0] %>"
       class="btn btn-sm <%= $filter eq $f->[0] ? 'btn-dark' : 'btn-outline-secondary' %>"><%= $f->[1] %></a>
  % }
  <span class="ms-3 text-muted small"><%= $total_items %> records</span>
</div>

<table class="table table-sm table-hover bg-white">
  <thead class="table-light">
    <tr>
      <th>VAERS ID</th>
      <th>Year</th>
      <th>Extracted age</th>
      <th>Status</th>
      <th>Evidence</th>
      <th>Review</th>
      <th></th>
    </tr>
  </thead>
  <tbody>
    % for my $item (@$items) {
      % my $vid = $item->{vaers_id};
      % my $rv  = $reviews->{$vid};
      % my $ar  = archive_record($vid);
      <tr>
        <td><strong><%= $vid %></strong></td>
        <td><%= $ar->{file_year} // '?' %></td>
        <td>
          % if ($item->{age} ne 'null') {
            <strong><%= $item->{age} %></strong>
          % } else {
            <span class="text-muted">—</span>
          % }
        </td>
        <td>
          % my $st = $item->{status} // '';
          % my $st_class = $st eq 'ok' ? 'success' : ($st eq 'ambiguous' ? 'warning' : ($st eq 'missing' ? 'secondary' : 'danger'));
          <span class="badge bg-<%= $st_class %>"><%= $st %></span>
        </td>
        <td class="text-muted" style="max-width:300px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">
          <%= $item->{evidence} %>
        </td>
        <td>
          % if ($rv) {
            % my $d = $rv->{decision} // '';
            <span class="badge badge-<%= $d %>"><%= $d %></span>
          % } else {
            <span class="badge badge-pending">pending</span>
          % }
        </td>
        <td>
          <a href="/ages/review/<%= $vid %>?from=all" class="btn btn-sm btn-outline-primary">Review</a>
        </td>
      </tr>
    % }
  </tbody>
</table>

<!-- Pagination -->
% if ($total_pages > 1) {
  <nav>
    <ul class="pagination pagination-sm justify-content-center">
      % for my $p (1 .. $total_pages) {
        <li class="page-item <%= $p == $page ? 'active' : '' %>">
          <a class="page-link" href="/ages?filter=<%= $filter %>&page=<%= $p %>"><%= $p %></a>
        </li>
      % }
    </ul>
  </nav>
% }


@@ ages_found_list.html.ep
% layout 'default';
% title 'Ages Found — Review';

<div class="d-flex justify-content-between align-items-center mb-3">
  <h4 class="mb-0">Ages Found — Validation <small class="text-muted">(status=ok only)</small></h4>
  <div>
    <span class="badge bg-success"><%= $stats->{reviewed} %> / <%= $stats->{total} %> reviewed (<%= $stats->{pct} %>%)</span>
  </div>
</div>

<!-- Filters -->
<div class="filter-bar mb-3">
  % my @filters = (
  %   ['all',      'All found'],
  %   ['pending',  'Pending'],
  %   ['reviewed', 'Reviewed'],
  % );
  % for my $f (@filters) {
    <a href="/ages/found?filter=<%= $f->[0] %>"
       class="btn btn-sm <%= $filter eq $f->[0] ? 'btn-dark' : 'btn-outline-secondary' %>"><%= $f->[1] %></a>
  % }
  <span class="ms-3 text-muted small"><%= $total_items %> records</span>
</div>

<table class="table table-sm table-hover bg-white">
  <thead class="table-light">
    <tr>
      <th>VAERS ID</th>
      <th>Year</th>
      <th>Extracted age</th>
      <th>Evidence</th>
      <th>Review</th>
      <th></th>
    </tr>
  </thead>
  <tbody>
    % for my $item (@$items) {
      % my $vid = $item->{vaers_id};
      % my $rv  = $reviews->{$vid};
      % my $ar  = archive_record($vid);
      <tr>
        <td><strong><%= $vid %></strong></td>
        <td><%= $ar->{file_year} // '?' %></td>
        <td><strong><%= $item->{age} %></strong></td>
        <td class="text-muted" style="max-width:350px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">
          <%= $item->{evidence} %>
        </td>
        <td>
          % if ($rv) {
            % my $d = $rv->{decision} // '';
            <span class="badge badge-<%= $d %>"><%= $d %></span>
            % if ($d eq 'corrected' && defined $rv->{corrected_age}) {
              <small class="text-info ms-1">→ <%= $rv->{corrected_age} %></small>
            % }
          % } else {
            <span class="badge badge-pending">pending</span>
          % }
        </td>
        <td>
          <a href="/ages/review/<%= $vid %>?from=found" class="btn btn-sm btn-outline-primary">Review</a>
        </td>
      </tr>
    % }
  </tbody>
</table>

<!-- Pagination -->
% if ($total_pages > 1) {
  <nav>
    <ul class="pagination pagination-sm justify-content-center">
      % for my $p (1 .. $total_pages) {
        <li class="page-item <%= $p == $page ? 'active' : '' %>">
          <a class="page-link" href="/ages/found?filter=<%= $filter %>&page=<%= $p %>"><%= $p %></a>
        </li>
      % }
    </ul>
  </nav>
% }


@@ age_review.html.ep
% layout 'default';
% title "Age Review — $rec->{vaers_id}";
% my $back_url = ($from eq 'found') ? '/ages/found?filter=pending' : '/ages?filter=pending';
% my $track_label = ($from eq 'found') ? 'Found' : 'All';

<div class="d-flex justify-content-between align-items-center mb-3">
  <h4 class="mb-0">
    Age Review — VAERS #<%= $rec->{vaers_id} %>
    <small class="text-muted ms-2">Year: <%= $archive->{file_year} // '?' %></small>
    <span class="badge bg-secondary ms-2" style="font-size:.65rem;vertical-align:middle"><%= $track_label %></span>
  </h4>
  <div>
    <span class="badge bg-primary"><%= $stats->{reviewed} %> / <%= $stats->{total} %> (<%= $stats->{pct} %>%)</span>
    <a href="<%= $back_url %>" class="btn btn-sm btn-outline-secondary ms-2">Back to list</a>
  </div>
</div>

<div class="row g-3">
  <!-- Left: symptom text -->
  <div class="col-lg-7">
    <h6>Symptom Text</h6>
    <div class="symptom-box"><%== highlight_age_in_text(
        Mojo::Util::xml_escape($archive->{symptom_text} // '(no text available)'),
        $rec->{age}
    ) %></div>
  </div>

  <!-- Right: LLM output + review form -->
  <div class="col-lg-5">

    <!-- LLM extraction -->
    <div class="llm-card mb-3">
      <h6 class="mb-2">LLM Extraction (gemma4)</h6>
      <table class="table table-sm table-borderless mb-1">
        <tr><th style="width:100px">Age</th>
            <td>
              % if ($rec->{age} ne 'null') {
                <strong class="fs-5"><%= $rec->{age} %></strong> years
              % } else {
                <span class="text-muted">null</span>
              % }
            </td>
        </tr>
        <tr><th>Status</th>
            <td>
              % my $st = $rec->{status} // '';
              % my $st_class = $st eq 'ok' ? 'success' : ($st eq 'ambiguous' ? 'warning' : ($st eq 'missing' ? 'secondary' : 'danger'));
              <span class="badge bg-<%= $st_class %>"><%= $st %></span>
            </td>
        </tr>
        <tr><th>Evidence</th><td class="fst-italic"><%= $rec->{evidence} %></td></tr>
      </table>
    </div>

    <!-- Review form -->
    <div class="review-form">
      <h6 class="mb-3">Your Review</h6>
      <form method="POST" action="/ages/review/<%= $rec->{vaers_id} %>" id="reviewForm">
        <input type="hidden" name="next_unreviewed" value="<%= $next_unreviewed // '' %>">
        <input type="hidden" name="from" value="<%= $from %>">

        <div class="mb-3">
          <label class="form-label fw-bold">Decision</label>
          <div class="d-flex gap-2 flex-wrap">
            % my $cur_d = $review->{decision} // '';
            <div class="form-check">
              <input class="form-check-input" type="radio" name="decision" id="d_validated"
                     value="validated" <%= $cur_d eq 'validated' ? 'checked' : '' %>>
              <label class="form-check-label" for="d_validated">
                Validated <kbd>1</kbd>
              </label>
            </div>
            <div class="form-check">
              <input class="form-check-input" type="radio" name="decision" id="d_corrected"
                     value="corrected" <%= $cur_d eq 'corrected' ? 'checked' : '' %>>
              <label class="form-check-label" for="d_corrected">
                Corrected <kbd>2</kbd>
              </label>
            </div>
            <div class="form-check">
              <input class="form-check-input" type="radio" name="decision" id="d_rejected"
                     value="rejected" <%= $cur_d eq 'rejected' ? 'checked' : '' %>>
              <label class="form-check-label" for="d_rejected">
                Rejected <kbd>3</kbd>
              </label>
            </div>
          </div>
        </div>

        <div class="mb-3" id="corrected_age_row" style="<%= $cur_d eq 'corrected' ? '' : 'display:none' %>">
          <label class="form-label" for="corrected_age">Corrected age (years)</label>
          <input type="number" step="0.01" min="0" max="120" class="form-control form-control-sm"
                 id="corrected_age" name="corrected_age"
                 value="<%= $review->{corrected_age} // '' %>"
                 placeholder="e.g. 0.5 for 6 months">
        </div>

        <div class="mb-3">
          <label class="form-label" for="notes">Notes (optional)</label>
          <textarea class="form-control form-control-sm" id="notes" name="notes"
                    rows="2" placeholder="Any remarks..."><%= $review->{notes} // '' %></textarea>
        </div>

        <div class="d-flex justify-content-between">
          <button type="submit" class="btn btn-primary">
            Save & next <kbd>Enter</kbd>
          </button>
          % if ($next_unreviewed) {
            <a href="/ages/review/<%= $next_unreviewed %>?from=<%= $from %>" class="btn btn-outline-secondary btn-sm">
              Skip to next →
            </a>
          % }
        </div>
      </form>
    </div>

  </div>
</div>

<script>
// Keyboard shortcuts
document.addEventListener('keydown', function(e) {
  // Don't trigger if typing in textarea/input
  if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT') return;

  if (e.key === '1') { document.getElementById('d_validated').checked = true; toggleCorrAge(); }
  if (e.key === '2') { document.getElementById('d_corrected').checked = true; toggleCorrAge(); document.getElementById('corrected_age').focus(); }
  if (e.key === '3') { document.getElementById('d_rejected').checked = true; toggleCorrAge(); }
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    document.getElementById('reviewForm').submit();
  }
});

// Toggle corrected age field
document.querySelectorAll('input[name="decision"]').forEach(function(r) {
  r.addEventListener('change', toggleCorrAge);
});

function toggleCorrAge() {
  var row = document.getElementById('corrected_age_row');
  var isCorrected = document.getElementById('d_corrected').checked;
  row.style.display = isCorrected ? '' : 'none';
}
</script>


@@ severity_list.html.ep
% layout 'default';
% title 'Severity Review';

<div class="d-flex justify-content-between align-items-center mb-3">
  <h4 class="mb-0">Severity Classification Review (Minors)</h4>
  <div>
    <span class="badge bg-danger"><%= $stats->{reviewed} %> / <%= $stats->{total} %> reviewed (<%= $stats->{pct} %>%)</span>
  </div>
</div>

<!-- Filters -->
<div class="filter-bar mb-3">
  % my @filters = (
  %   ['all',      'All'],
  %   ['pending',  'Pending'],
  %   ['reviewed', 'Reviewed'],
  %   ['deaths',   'Deaths only'],
  %   ['severe',   'Any severe'],
  % );
  % for my $f (@filters) {
    <a href="/severity?filter=<%= $f->[0] %>"
       class="btn btn-sm <%= $filter eq $f->[0] ? 'btn-dark' : 'btn-outline-secondary' %>"><%= $f->[1] %></a>
  % }
  <span class="ms-3 text-muted small"><%= $total_items %> records</span>
</div>

<table class="table table-sm table-hover bg-white">
  <thead class="table-light">
    <tr>
      <th>VAERS ID</th>
      <th>Age</th>
      <th>Life-threat.</th>
      <th>Died</th>
      <th>Disability</th>
      <th>Evidence</th>
      <th>Review</th>
      <th></th>
    </tr>
  </thead>
  <tbody>
    % for my $item (@$items) {
      % my $vid = $item->{vaers_id};
      % my $rv  = $reviews->{$vid};
      <tr class="<%= ($item->{subject_died} // '') eq 'yes' ? 'table-danger' : '' %>">
        <td><strong><%= $vid %></strong></td>
        <td><%= $item->{age} ne 'null' ? $item->{age} : '—' %></td>
        <td>
          % if (($item->{life_threatening} // '') eq 'yes') {
            <span class="badge bg-warning text-dark">yes</span>
          % } else {
            <span class="text-muted">no</span>
          % }
        </td>
        <td>
          % if (($item->{subject_died} // '') eq 'yes') {
            <span class="badge bg-danger">yes</span>
          % } else {
            <span class="text-muted">no</span>
          % }
        </td>
        <td>
          % if (($item->{disability} // '') eq 'yes') {
            <span class="badge bg-dark">yes</span>
          % } else {
            <span class="text-muted">no</span>
          % }
        </td>
        <td class="text-muted" style="max-width:250px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">
          <%= $item->{evidence} %>
        </td>
        <td>
          % if ($rv) {
            % my $d = $rv->{decision} // '';
            <span class="badge badge-<%= $d %>"><%= $d %></span>
            % if (($rv->{death_type} // '') ne '') {
              <span class="badge bg-secondary"><%= $rv->{death_type} %></span>
            % }
          % } else {
            <span class="badge badge-pending">pending</span>
          % }
        </td>
        <td>
          <a href="/severity/review/<%= $vid %>" class="btn btn-sm btn-outline-danger">Review</a>
        </td>
      </tr>
    % }
  </tbody>
</table>

<!-- Pagination -->
% if ($total_pages > 1) {
  <nav>
    <ul class="pagination pagination-sm justify-content-center">
      % for my $p (1 .. $total_pages) {
        <li class="page-item <%= $p == $page ? 'active' : '' %>">
          <a class="page-link" href="/severity?filter=<%= $filter %>&page=<%= $p %>"><%= $p %></a>
        </li>
      % }
    </ul>
  </nav>
% }


@@ severity_review.html.ep
% layout 'default';
% title "Severity Review — $rec->{vaers_id}";

<div class="d-flex justify-content-between align-items-center mb-3">
  <h4 class="mb-0">
    Severity Review — VAERS #<%= $rec->{vaers_id} %>
    <small class="text-muted ms-2">Age: <%= $rec->{age} ne 'null' ? $rec->{age} : '?' %></small>
  </h4>
  <div>
    <span class="badge bg-danger"><%= $stats->{reviewed} %> / <%= $stats->{total} %> (<%= $stats->{pct} %>%)</span>
    <a href="/severity?filter=pending" class="btn btn-sm btn-outline-secondary ms-2">Back to list</a>
  </div>
</div>

<div class="row g-3">
  <!-- Left: symptom text -->
  <div class="col-lg-7">
    <h6>Symptom Text</h6>
    <div class="symptom-box"><%==
      do {
        my $txt = Mojo::Util::xml_escape($archive->{symptom_text} // '(no text available)');
        # Highlight death-related keywords
        $txt =~ s/\b(died|death|deceased|expired|fatal|stillb\w*|miscarriage|neonatal\s+death)\b/<mark class="death-hl">$1<\/mark>/gi;
        # Highlight life-threatening keywords
        $txt =~ s/\b(anaphylax\w*|cardiac\s+arrest|seizure|ICU|code\s+blue|intubat\w*|resuscitat\w*)\b/<mark class="age-hl">$1<\/mark>/gi;
        $txt;
      }
    %></div>
  </div>

  <!-- Right: LLM output + review form -->
  <div class="col-lg-5">

    <!-- LLM classification -->
    <div class="llm-card mb-3">
      <h6 class="mb-2">LLM Classification (gemma4)</h6>
      <table class="table table-sm table-borderless mb-1">
        <tr>
          <th style="width:130px">Life-threatening</th>
          <td>
            % if (($rec->{life_threatening} // '') eq 'yes') {
              <span class="badge bg-warning text-dark fs-6">YES</span>
            % } else {
              <span class="text-muted">no</span>
            % }
          </td>
        </tr>
        <tr>
          <th>Subject died</th>
          <td>
            % if (($rec->{subject_died} // '') eq 'yes') {
              <span class="badge bg-danger fs-6">YES</span>
            % } else {
              <span class="text-muted">no</span>
            % }
          </td>
        </tr>
        <tr>
          <th>Disability</th>
          <td>
            % if (($rec->{disability} // '') eq 'yes') {
              <span class="badge bg-dark fs-6">YES</span>
            % } else {
              <span class="text-muted">no</span>
            % }
          </td>
        </tr>
        <tr><th>Evidence</th><td class="fst-italic"><%= $rec->{evidence} %></td></tr>
      </table>
    </div>

    <!-- Review form -->
    <div class="review-form">
      <h6 class="mb-3">Your Review</h6>
      <form method="POST" action="/severity/review/<%= $rec->{vaers_id} %>" id="reviewForm">
        <input type="hidden" name="next_unreviewed" value="<%= $next_unreviewed // '' %>">

        <!-- Decision -->
        <div class="mb-3">
          <label class="form-label fw-bold">Decision</label>
          <div class="d-flex gap-2 flex-wrap">
            % my $cur_d = $review->{decision} // '';
            <div class="form-check">
              <input class="form-check-input" type="radio" name="decision" id="d_validated"
                     value="validated" <%= $cur_d eq 'validated' ? 'checked' : '' %>>
              <label class="form-check-label" for="d_validated">Validated <kbd>1</kbd></label>
            </div>
            <div class="form-check">
              <input class="form-check-input" type="radio" name="decision" id="d_corrected"
                     value="corrected" <%= $cur_d eq 'corrected' ? 'checked' : '' %>>
              <label class="form-check-label" for="d_corrected">Corrected <kbd>2</kbd></label>
            </div>
            <div class="form-check">
              <input class="form-check-input" type="radio" name="decision" id="d_excluded"
                     value="excluded" <%= $cur_d eq 'excluded' ? 'checked' : '' %>>
              <label class="form-check-label" for="d_excluded">Exclude (error) <kbd>3</kbd></label>
            </div>
          </div>
        </div>

        <!-- Overrides (shown when "corrected") -->
        <div id="override_section" style="<%= $cur_d eq 'corrected' ? '' : 'display:none' %>">
          <div class="row g-2 mb-3">
            <div class="col-6">
              <label class="form-label">Life-threatening override</label>
              <select class="form-select form-select-sm" name="lt_override">
                % my $lto = $review->{lt_override} // '';
                <option value="" <%= $lto eq '' ? 'selected' : '' %>>— keep LLM —</option>
                <option value="yes" <%= $lto eq 'yes' ? 'selected' : '' %>>Yes</option>
                <option value="no" <%= $lto eq 'no' ? 'selected' : '' %>>No</option>
              </select>
            </div>
            <div class="col-6">
              <label class="form-label">Disability override</label>
              <select class="form-select form-select-sm" name="disability_override">
                % my $do = $review->{disability_override} // '';
                <option value="" <%= $do eq '' ? 'selected' : '' %>>— keep LLM —</option>
                <option value="yes" <%= $do eq 'yes' ? 'selected' : '' %>>Yes</option>
                <option value="no" <%= $do eq 'no' ? 'selected' : '' %>>No</option>
              </select>
            </div>
          </div>
        </div>

        <!-- Death classification (shown when LLM says died=yes OR decision=corrected) -->
        <div class="mb-3" id="death_section"
             style="<%= (($rec->{subject_died} // '') eq 'yes' || $cur_d eq 'corrected') ? '' : 'display:none' %>">
          <label class="form-label fw-bold">Death classification</label>
          <div class="d-flex gap-2 flex-wrap">
            % my $dt = $review->{death_type} // '';
            <div class="form-check">
              <input class="form-check-input" type="radio" name="death_type" id="dt_subject"
                     value="subject" <%= $dt eq 'subject' ? 'checked' : '' %>>
              <label class="form-check-label" for="dt_subject">
                Vaccinated subject died <kbd>S</kbd>
              </label>
            </div>
            <div class="form-check">
              <input class="form-check-input" type="radio" name="death_type" id="dt_child"
                     value="child" <%= $dt eq 'child' ? 'checked' : '' %>>
              <label class="form-check-label" for="dt_child">
                Child / offspring died <kbd>C</kbd>
              </label>
            </div>
            <div class="form-check">
              <input class="form-check-input" type="radio" name="death_type" id="dt_none"
                     value="none" <%= $dt eq 'none' ? 'checked' : '' %>>
              <label class="form-check-label" for="dt_none">
                No death (LLM error) <kbd>N</kbd>
              </label>
            </div>
          </div>
        </div>

        <!-- Cause of death -->
        <div class="mb-3" id="cod_section"
             style="<%= (($rec->{subject_died} // '') eq 'yes' || $cur_d eq 'corrected') ? '' : 'display:none' %>">
          <label class="form-label" for="cause_of_death">Apparent cause of death <small class="text-muted">(optional)</small></label>
          <input type="text" class="form-control form-control-sm" id="cause_of_death"
                 name="cause_of_death" value="<%= $review->{cause_of_death} // '' %>"
                 placeholder="e.g. SIDS, cardiac arrest, anaphylaxis, stillbirth...">
        </div>

        <!-- Notes -->
        <div class="mb-3">
          <label class="form-label" for="notes">Notes <small class="text-muted">(optional)</small></label>
          <textarea class="form-control form-control-sm" id="notes" name="notes"
                    rows="2" placeholder="Any remarks..."><%= $review->{notes} // '' %></textarea>
        </div>

        <div class="d-flex justify-content-between">
          <button type="submit" class="btn btn-danger">
            Save & next <kbd>Enter</kbd>
          </button>
          % if ($next_unreviewed) {
            <a href="/severity/review/<%= $next_unreviewed %>" class="btn btn-outline-secondary btn-sm">
              Skip to next →
            </a>
          % }
        </div>
      </form>
    </div>

  </div>
</div>

<script>
document.addEventListener('keydown', function(e) {
  if (e.target.tagName === 'TEXTAREA' || e.target.tagName === 'INPUT') return;

  if (e.key === '1') { document.getElementById('d_validated').checked = true; toggleSections(); }
  if (e.key === '2') { document.getElementById('d_corrected').checked = true; toggleSections(); }
  if (e.key === '3') { document.getElementById('d_excluded').checked = true; toggleSections(); }

  // Death type shortcuts (case-insensitive)
  var k = e.key.toLowerCase();
  if (k === 's') document.getElementById('dt_subject').checked = true;
  if (k === 'c') document.getElementById('dt_child').checked = true;
  if (k === 'n') document.getElementById('dt_none').checked = true;

  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    document.getElementById('reviewForm').submit();
  }
});

document.querySelectorAll('input[name="decision"]').forEach(function(r) {
  r.addEventListener('change', toggleSections);
});

function toggleSections() {
  var isCorrected = document.getElementById('d_corrected').checked;
  var diedYes     = '<%= ($rec->{subject_died} // '') %>' === 'yes';

  document.getElementById('override_section').style.display = isCorrected ? '' : 'none';
  document.getElementById('death_section').style.display    = (diedYes || isCorrected) ? '' : 'none';
  document.getElementById('cod_section').style.display      = (diedYes || isCorrected) ? '' : 'none';
}
</script>
