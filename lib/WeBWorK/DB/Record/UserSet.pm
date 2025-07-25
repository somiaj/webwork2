package WeBWorK::DB::Record::UserSet;
use base WeBWorK::DB::Record;

=head1 NAME

WeBWorK::DB::Record::UserSet - represent a record from the set_user table.

=cut

use strict;
use warnings;

BEGIN {
	__PACKAGE__->_fields(
		user_id                   => { type => "VARCHAR(100) NOT NULL", key => 1 },
		set_id                    => { type => "VARCHAR(100) NOT NULL", key => 1 },
		psvn                      => { type => "INT UNIQUE NOT NULL AUTO_INCREMENT" },
		set_header                => { type => "TEXT" },
		hardcopy_header           => { type => "TEXT" },
		open_date                 => { type => "BIGINT" },
		due_date                  => { type => "BIGINT" },
		answer_date               => { type => "BIGINT" },
		reduced_scoring_date      => { type => "BIGINT" },
		visible                   => { type => "INT" },
		enable_reduced_scoring    => { type => "INT" },
		assignment_type           => { type => "TEXT" },
		description               => { type => "TEXT" },
		restricted_release        => { type => "TEXT" },
		restricted_status         => { type => "FLOAT" },
		attempts_per_version      => { type => "INT" },
		time_interval             => { type => "INT" },
		versions_per_interval     => { type => "INT" },
		version_time_limit        => { type => "INT" },
		version_creation_time     => { type => "BIGINT" },
		problem_randorder         => { type => "INT" },
		version_last_attempt_time => { type => "BIGINT" },
		problems_per_page         => { type => "INT" },
		hide_score                => { type => "ENUM('N','Y','BeforeAnswerDate')" },
		hide_score_by_problem     => { type => "ENUM('N','Y')" },
		hide_work                 => { type => "ENUM('N','Y','BeforeAnswerDate')" },
		time_limit_cap            => { type => "ENUM('0','1')" },
		restrict_ip               => { type => "ENUM('No','RestrictTo','DenyFrom')" },
		relax_restrict_ip         => { type => "ENUM('No','AfterAnswerDate','AfterVersionAnswerDate')" },
		restricted_login_proctor  => { type => "ENUM('No','Yes')" },
		use_grade_auth_proctor    => { type => "ENUM('No','Yes')" },
		hide_hint                 => { type => "INT" },
		restrict_prob_progression => { type => "INT" },
		email_instructor          => { type => "INT" },
		lis_source_did            => { type => "TEXT" },
		external_data             => { type => "MEDIUMTEXT" },
	);
}

1;
