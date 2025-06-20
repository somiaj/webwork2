# This page is for triggering LTI grade updates

package WeBWorK::ContentGenerator::Instructor::LTIUpdate;
use Mojo::Base 'WeBWorK::ContentGenerator', -signatures;

use WeBWorK::Utils::Sets                qw(format_set_name_display);
use WeBWorK::Authen::LTI::GradePassback qw(massUpdate);

sub initialize ($c) {
	my $db = $c->db;
	my $ce = $c->ce;

	# Make sure these are defined for the template.
	$c->stash->{sets}       = [];
	$c->stash->{users}      = [];
	$c->stash->{lastUpdate} = 0;

	return unless ($c->authz->hasPermissions($c->param('user'), 'score_sets') && $ce->{LTIGradeMode});

	$c->stash->{sets}       = [ sort $db->listGlobalSets ] if $ce->{LTIGradeMode} eq 'homework';
	$c->stash->{users}      = [ sort $db->listUsers ];
	$c->stash->{lastUpdate} = $db->getSettingValue('LTILastUpdate') || 0;

	return unless ($c->param('updateLTI'));

	my @setIDs  = ($c->param('updateSetID'));
	my $userID  = $c->param('updateUserID');
	my $allSets = $c->param('selectAllSets');

	# Test if setID and userID are valid.
	if ($userID && !$db->getUser($userID)) {
		$c->addbadmessage($c->maketext('Update aborted. Invalid user [_1].', $userID));
		return;
	}
	if ($ce->{LTIGradeMode} eq 'homework' && !@setIDs) {
		$c->addbadmessage($c->maketext('Update aborted. No sets selected.'));
		return;
	}

	if ($userID) {
		$c->addgoodmessage($c->maketext('LTI update of user [_1] queued.', $userID));
	} elsif ($allSets) {
		$c->addgoodmessage($c->maketext('LTI update of all users queued.'));
	} else {
		$c->addgoodmessage($c->maketext('LTI update of all users and sets queued.'));
	}

	# Note that if somehow this point is reached with a setIDs and grade mode is "course",
	# then the setIDs will be ignored by the job.

	massUpdate($c, 1, $userID, $allSets ? '' : \@setIDs);

	return;
}

sub format_interval ($c, $seconds) {
	my $minutes = int($seconds / 60);
	my $hours   = int($minutes / 60);
	my $days    = int($hours / 24);
	my $out     = '';

	return $c->maketext('0 seconds') unless $seconds > 0;

	$seconds = $seconds - 60 * $minutes;
	$minutes = $minutes - 60 * $hours;
	$hours   = $hours - 24 * $days;

	$out .= $c->maketext('[quant,_1,day]',    $days) . ' '    if $days;
	$out .= $c->maketext('[quant,_1,hour]',   $hours) . ' '   if $hours;
	$out .= $c->maketext('[quant,_1,minute]', $minutes) . ' ' if $minutes;
	$out .= $c->maketext('[quant,_1,second]', $seconds) . ' ' if $seconds;
	chop($out);

	return $out;
}

1;
