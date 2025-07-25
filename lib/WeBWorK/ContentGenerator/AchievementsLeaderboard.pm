# Leader board for achievements.
package WeBWorK::ContentGenerator::AchievementsLeaderboard;
use Mojo::Base 'WeBWorK::ContentGenerator', -signatures;

=head1 NAME

WeBWorK::ContentGenerator::AchievementsLeaderboard - Leaderboard for achievements,
which lists the total number of achievement points, level, and badges
earned for each user with the 'include_in_stats' status.

Only users with the 'view_leaderboard' permission can see the Leaderboard, and only
users with the 'view_leaderboard_usernames' permission can see user names.

=cut

use WeBWorK::Utils qw(sortAchievements);

sub initialize ($c) {
	my $db = $c->db;
	my $ce = $c->ce;

	# Get user Data
	$c->{userName}    = $c->param('user');
	$c->{studentName} = $c->param('effectiveUser') // $c->{userName};

	return unless $c->authz->hasPermissions($c->{userName}, 'view_leaderboard');

	# Get list of all users (except set-level proctors) and achievements.
	my @achievements     = sortAchievements($db->getAchievementsWhere);
	my %achievementsById = map { $_->achievement_id => $_ } @achievements;
	my %globalUserAchievements =
		map { $_->user_id => $_ } $db->getGlobalUserAchievementsWhere({ user_id => { not_like => 'set_id:%' } });

	$c->{showUserNames} = $c->authz->hasPermissions($c->{userName}, 'view_leaderboard_usernames');
	$c->{showLevels}    = 0;    # Hide level column unless at least one user has a level achievement.

	my %allUserAchievements;
	for ($db->getUserAchievementsWhere({
		user_id        => { not_like => 'set_id:%' },
		achievement_id => [ map { $_->achievement_id } grep { $_->category ne 'level' } @achievements ],
	}))
	{
		$allUserAchievements{ $_->user_id }{ $_->achievement_id } = $_;
	}

	my @rows;
	for my $user ($db->getUsersWhere({ user_id => { not_like => 'set_id:%' } })) {
		# Only include users who can be shown in stats.
		next unless $ce->status_abbrev_has_behavior($user->status, 'include_in_stats');

		my $globalData       = $globalUserAchievements{ $user->user_id };
		my $userAchievements = $allUserAchievements{ $user->user_id };

		# Skip unless user has achievement data.
		next unless $globalData && $userAchievements;

		my $level = $globalData->level_achievement_id ? $achievementsById{ $globalData->level_achievement_id } : '';

		my @badges;
		for my $achievement (@achievements) {
			# Skip level achievements and only show earned achievements.
			last if $achievement->category eq 'level';

			push(@badges, $achievement)
				if $userAchievements->{ $achievement->achievement_id }
				&& $achievement->enabled
				&& $userAchievements->{ $achievement->achievement_id }->earned;
		}

		push(@rows, [ $globalData->achievement_points || 0, $level, $user, \@badges ]);
	}

	# Sort rows descending by achievement points (or number of badges if achievement points are equal)
	# then loop over them to compute rank and determine rank of effective student user.
	my $rank        = 0;
	my $prev_points = -1;
	my $skip        = 1;
	@rows = sort { $b->[0] <=> $a->[0] || scalar(@{ $b->[3] }) <=> scalar(@{ $a->[3] }) } @rows;
	for my $row (@rows) {
		# All users with an equal number of achievement points have the same rank.
		if ($row->[0] == $prev_points) {
			$skip++;
		} else {
			$rank += $skip;
			$skip = 1;
		}
		$prev_points = $row->[0];
		unshift(@$row, $rank);

		$c->{showLevels}  = 1     if $row->[2];
		$c->{currentRank} = $rank if $c->{studentName} eq $row->[3]->user_id;
	}
	$c->{maxRank}         = $rank;
	$c->{leaderBoardRows} = \@rows;

	return;
}

1;
