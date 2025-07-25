package WeBWorK::Authen::LTIAdvanced::SubmitGrade;

=head1 NAME

WeBWorK::Authen::LTIAdvanced::SubmitGrade - pass back grades to an enabled LMS

=cut

use Mojo::Base -signatures, -async_await;

use Net::OAuth;
use Mojo::UserAgent;
use UUID::Tiny ':std';
use Digest::SHA qw(sha1_base64);

use WeBWorK::Debug;
use WeBWorK::Utils                      qw(wwRound);
use WeBWorK::Utils::Sets                qw(grade_all_sets);
use WeBWorK::Authen::LTI::GradePassback qw(getSetPassbackScore);

# This package contains utilities for submitting grades to the LMS
sub new ($invocant, $c, $post_processing_mode = 0) {
	return bless { c => $c, post_processing_mode => $post_processing_mode }, ref($invocant) || $invocant;
}

# Use the app log for warnings in post processing mode as perl warnings are not caught in the job queue.
# Otherwise just use warn as those are caught by the global webwork2 warn handler.
sub warning ($self, $warning) {
	if ($self->{post_processing_mode}) {
		$self->{c}{app}->log->warn($warning);
	} else {
		warn $warning . "\n";
	}
	return;
}

# This updates the sourcedid for the object we are looking at.  Its either
# the sourcedid for the user for course grades or the sourcedid for the
# userset for homework grades.
sub update_sourcedid ($self, $userID) {
	my $c  = $self->{c};
	my $ce = $c->{ce};
	my $db = $c->{db};

	# These parameters are used to build the passback request
	# warn if no outcome service url
	if (!defined($c->param('lis_outcome_service_url'))) {
		warn 'The parameter lis_outcome_service_url is not defined.  Unable to report grades to the LMS.'
			. " Are external grades enabled in the LMS?\n"
			if $ce->{debug_lti_grade_passback};
	} else {
		# otherwise keep it up to date
		my $lis_outcome_service_url = $db->getSettingValue('lis_outcome_service_url');
		if (!defined($lis_outcome_service_url) || $lis_outcome_service_url ne $c->param('lis_outcome_service_url')) {
			$db->setSettingValue('lis_outcome_service_url', $c->param('lis_outcome_service_url'));
		}
	}

	# these parameters have to be here or we couldn't have gotten this far
	my $consumer_key = $db->getSettingValue('consumer_key');
	if (!defined($consumer_key) || $consumer_key ne $c->param('oauth_consumer_key')) {
		$db->setSettingValue('consumer_key', $c->param('oauth_consumer_key'));
	}

	my $signature_method = $db->getSettingValue('signature_method');
	if (!defined($signature_method) || $signature_method ne $c->param('oauth_signature_method')) {
		$db->setSettingValue('signature_method', $c->param('oauth_signature_method'));
	}

	# The $sourcedid is what identifies the user and assignment
	# to the LMS.  It is either a course grade or a set grade
	# depending on the request and the mode we are in.
	my $sourcedid = $c->param('lis_result_sourcedid');
	if (!defined($sourcedid)) {
		warn q{No LISSourceID! Some LMS's do not give grades to instructors, but this }
			. "could also be a sign that external grades are not enabled in your LMS.\n"
			if $ce->{debug_lti_grade_passback};
	} elsif ($ce->{LTIGradeMode} eq 'course') {
		# Update the SourceDID for the user if we are in course mode
		my $User = $db->getUser($userID);
		if (!defined($User->lis_source_did) || $User->lis_source_did ne $sourcedid) {
			$User->lis_source_did($sourcedid);
			$db->putUser($User);
		}
	} elsif ($ce->{LTIGradeMode} eq 'homework') {
		my $setID = $c->stash('setID');
		if (!defined($setID)) {
			warn 'Not a link to a Problem Set and in homework grade mode.'
				. ' Links to WeBWorK should point to specific problem sets.';
		} else {
			my $set = $db->getUserSet($userID, $setID);
			if (defined($set) && (!defined($set->lis_source_did) || $set->lis_source_did ne $sourcedid)) {
				$set->lis_source_did($sourcedid);
				$db->putUserSet($set);
			}
		}
	}

	return;
}

# Computes and submits the course grade for userID to the LMS.
# The course grade is the average of all sets assigned to the user.
async sub submit_course_grade ($self, $userID, $submittedSet = undef) {
	my $c  = $self->{c};
	my $ce = $c->{ce};
	my $db = $c->{db};

	my $user = $db->getUser($userID);
	return 0 unless $user;

	$self->warning("Preparing to submit overall course grade to LMS for user $userID.")
		if $ce->{debug_lti_grade_passback} || $self->{post_processing_mode};

	unless ($user->lis_source_did) {
		$self->warning("lis_source_did is not available for this user")
			if $ce->{debug_lti_grade_passback} || $self->{post_processing_mode};
		return 0;
	}

	if ($submittedSet && !getSetPassbackScore($db, $ce, $userID, $submittedSet, 1)) {
		$self->warning("Set's critical date has not yet passed, and user has not yet met the threshold to send set's "
				. 'score early. Not submitting grade.');
		return -1;
	}

	my ($courseTotalRight, $courseTotal, $includedSets) = grade_all_sets($db, $ce, $userID, \&getSetPassbackScore);
	if (@$includedSets) {
		$self->warning(
			"Submitting overall score for user $userID for sets: " . join(', ', map { $_->set_id } @$includedSets))
			if $ce->{debug_lti_grade_passback} || $self->{post_processing_mode};
		my $score = $courseTotal ? $courseTotalRight / $courseTotal : 0;
		return await $self->submit_grade($user->lis_source_did, $score);
	} else {
		$self->warning("No sets for user $userID meet criteria to be included in course grade calculation.");
		return -1;
	}
}

# Computes and submits the set grade for $userID and $setID to the LMS.  For gateways the best score is used.
async sub submit_set_grade ($self, $userID, $setID, $submittedSet = undef) {
	my $c  = $self->{c};
	my $ce = $c->{ce};
	my $db = $c->{db};

	my $user = $db->getUser($userID);
	return 0 unless $user;

	$self->warning("Preparing to submit grade to LMS for user $userID and set $setID.")
		if $ce->{debug_lti_grade_passback} || $self->{post_processing_mode};

	my $userSet = $submittedSet // $db->getMergedSet($userID, $setID);
	unless ($userSet->lis_source_did) {
		$self->warning('lis_source_did is not available for this set.')
			if $ce->{debug_lti_grade_passback} || $self->{post_processing_mode};
		return 0;
	}

	my $score = getSetPassbackScore($db, $ce, $userID, $userSet, !$self->{post_processing_mode});
	unless ($score) {
		$self->warning("Set's critical date has not yet passed, and user has not yet met the threshold to send set's "
				. 'score early. Not submitting grade.');
		return -1;
	}

	return await $self->submit_grade($userSet->lis_source_did, $score->{score});
}

# Submits a score of $score to the lms with $sourcedid as the identifier.
async sub submit_grade ($self, $sourcedid, $score) {
	my $c  = $self->{c};
	my $ce = $c->{ce};
	my $db = $c->{db};

	$score = wwRound(2, $score);

	my $request_url = $db->getSettingValue('lis_outcome_service_url');
	if (!$request_url) {
		$self->warning('Cannot send/retrieve grades to/from the LMS, no lis_outcome_service_url');
		return 0;
	}

	my $consumer_key = $db->getSettingValue('consumer_key');
	if (!$consumer_key) {
		$self->warning('Cannot send/retrieve grades to/from the LMS, no consumer_key');
		return 0;
	}

	my $signature_method = $db->getSettingValue('signature_method');
	if (!$signature_method) {
		$self->warning('Cannot send/retrieve grades to/from the LMS, no signature_method');
		return 0;
	}

	debug('found data required for submitting grades to LMS');

	# Generate a nonce. Start with a portion that is unique for the sourcedid.  This should be dependent on the student.
	# If grade mode is "homework", this is also dependent on the assignment.  This part can be used twice.
	my $uuid_p1 = create_uuid_as_string(UUID_SHA1, UUID_NS_URL, $sourcedid);

	# The second part is time dependent.
	my $uuid_p2 = create_uuid_as_string(UUID_TIME);

	my $ua = Mojo::UserAgent->new;

	if ($ce->{LTICheckPrior} // 0) {
		# Poll the LMS for prior grade.

		# This is boilerplate XML used to retrieve the currently recorded score for $sourcedid
		# (which will later be tested)
		my $readResultXML = <<EOS;
<?xml version = "1.0" encoding = "UTF-8"?>
<imsx_POXEnvelopeRequest xmlns = "http://www.imsglobal.org/services/ltiv1p1/xsd/imsoms_v1p0">
  <imsx_POXHeader>
    <imsx_POXRequestHeaderInfo>
      <imsx_version>V1.0</imsx_version>
      <imsx_messageIdentifier>999999123</imsx_messageIdentifier>
    </imsx_POXRequestHeaderInfo>
  </imsx_POXHeader>
  <imsx_POXBody>
    <readResultRequest>
      <resultRecord>
        <sourcedGUID>
          <sourcedId>$sourcedid</sourcedId>
        </sourcedGUID>
      </resultRecord>
    </readResultRequest>
  </imsx_POXBody>
</imsx_POXEnvelopeRequest>
EOS

		chomp($readResultXML);

		my $bodyhash = sha1_base64($readResultXML);

		# Since sha1_base64 doesn't pad we have to do so manually.
		while (length($bodyhash) % 4) {
			$bodyhash .= '=';
		}

		$self->warning("Retrieving prior grade using sourcedid: $sourcedid")
			if $ce->{debug_lti_parameters} || $self->{post_processing_mode};

		my $requestGen = Net::OAuth->request('consumer');

		$requestGen->add_required_message_params('body_hash');

		my $gradeRequest = $requestGen->new(
			request_url      => $request_url,
			request_method   => 'POST',
			consumer_secret  => $ce->{LTI}{v1p1}{BasicConsumerSecret},
			consumer_key     => $consumer_key,
			signature_method => $signature_method,
			nonce            => "${uuid_p1}__${uuid_p2}",
			timestamp        => time,
			body_hash        => $bodyhash
		);
		$gradeRequest->sign();

		my $request = await $ua->post_p(
			$gradeRequest->request_url,
			{ 'Authorization' => $gradeRequest->to_authorization_header, 'Content-Type' => 'application/xml' },
			$readResultXML
		)->catch(sub ($err) {
				$self->warning("There was an error retrieving prior grade from the LMS: $err");
				return 0;
		});

		return 0 unless $request;
		my $response = $request->result;

		# Debug section
		if ($ce->{debug_lti_grade_passback} && $ce->{debug_lti_parameters}) {
			$self->warning("The request was:\n " . $readResultXML);
			$self->warning("The nonce used is ${uuid_p1}__${uuid_p2}");
			$self->warning("The response is:\n " . $response->to_string);
			debug("The request was:\n " . $readResultXML);
			debug("The nonce used is ${uuid_p1}__${uuid_p2}");
			debug("The response is:\n " . $response->to_string);
		}

		if ($response->is_success) {
			my $content = $response->body;
			$content =~ /<imsx_codeMajor>\s*(\w+)\s*<\/imsx_codeMajor>/;
			my $message = $1;
			if ($message ne 'success') {
				$self->warning('Unable to retrieve prior grade from LMS. Error: ' . $message);
				debug('Unable to retrieve prior grade from LMS. Error: ' . $message);
				return 0;
			} else {
				my $priorScore;
				# Possibly no score yet.
				if ($content =~ /<textString\/>/) {
					$priorScore = '';
				} else {
					$content =~ /<textString>\s*(\S+)\s*<\/textString>/;
					$priorScore = $1;
				}

				# Blackboard seems to return this when there is no prior grade.
				# See: https://webwork.maa.org/moodle/mod/forum/discuss.php?d=5002
				$priorScore = '' if $priorScore eq 'success';

				# Do not update the score if there is no significant change. Note that the cases where the webwork score
				# is exactly 1 and the LMS score is not exactly 1, and the case where the webwork score is 0 and the LMS
				# score is not set are considered significant changes.
				if (abs($score - ($priorScore || 0)) < 0.001
					&& ($score != 1 || $priorScore == 1)
					&& ($score != 0 || $priorScore ne ''))
				{
					# LMS has essentially the same score, no reason to update it
					debug('LMS grade will NOT be updated - grade has not significantly changed. '
							. "Old score: $priorScore; New score: $score")
						if $ce->{debug_lti_grade_passback};
					$self->warning('LMS grade will NOT be updated - grade has not significantly changed. '
							. "Old score: $priorScore; New score: $score")
						if $ce->{debug_lti_grade_passback} || $self->{post_processing_mode};
					return 1;
				} else {
					debug("LMS grade will be updated. sourcedid: $sourcedid; Old score: $priorScore; New score: $score")
						if $ce->{debug_lti_grade_passback};
				}
			}
		} else {
			$self->warning('Unable to retrieve prior grade from LMS. Error: ' . $response->message)
				if $ce->{debug_lti_grade_passback} || $self->{post_processing_mode};
			debug('Unable to retrieve prior grade from LMS. Error: ' . $response->message);
			debug($response->body);
			return 0;
		}
	}

	# Send the LMS the new grade

	# This is boilerplate XML used to submit the $score for $sourcedid
	my $replaceResultXML = <<EOS;
<?xml version = "1.0" encoding = "UTF-8"?>
<imsx_POXEnvelopeRequest xmlns = "http://www.imsglobal.org/services/ltiv1p1/xsd/imsoms_v1p0">
  <imsx_POXHeader>
    <imsx_POXRequestHeaderInfo>
      <imsx_version>V1.0</imsx_version>
      <imsx_messageIdentifier>999999123</imsx_messageIdentifier>
    </imsx_POXRequestHeaderInfo>
  </imsx_POXHeader>
  <imsx_POXBody>
    <replaceResultRequest>
      <resultRecord>
	<sourcedGUID>
	  <sourcedId>$sourcedid</sourcedId>
	</sourcedGUID>
	<result>
	  <resultScore>
	    <language>en</language>
	    <textString>$score</textString>
	  </resultScore>
	</result>
      </resultRecord>
    </replaceResultRequest>
  </imsx_POXBody>
</imsx_POXEnvelopeRequest>
EOS

	chomp($replaceResultXML);

	my $bodyhash = sha1_base64($replaceResultXML);

	# since sha1_base64 doesn't pad we have to do so manually
	while (length($bodyhash) % 4) {
		$bodyhash .= '=';
	}
	$self->warning("Submitting grade using sourcedid: $sourcedid and score: $score") if $ce->{debug_lti_grade_passback};

	my $requestGen = Net::OAuth->request('consumer');
	debug("obtained requestGen $requestGen");

	$requestGen->add_required_message_params('body_hash');

	# Change the time dependent portion of the nonce for the second stage
	$uuid_p2 .= '-step2';

	my $gradeRequest = $requestGen->new(
		request_url      => $request_url,
		request_method   => 'POST',
		consumer_secret  => $ce->{LTI}{v1p1}{BasicConsumerSecret},
		consumer_key     => $consumer_key,
		signature_method => $signature_method,
		nonce            => "${uuid_p1}__${uuid_p2}",
		timestamp        => time(),
		body_hash        => $bodyhash
	);
	debug("created grade request $gradeRequest");
	$gradeRequest->sign;
	debug('signed grade request');

	my $request = await $ua->post_p(
		$gradeRequest->request_url,
		{ 'Authorization' => $gradeRequest->to_authorization_header, 'Content-Type' => 'application/xml' },
		$replaceResultXML
	)->catch(sub ($err) {
			$self->warning("There was an error sending the grade to the LMS: $err");
			return 0;
	});

	return 0 unless $request;
	my $response = $request->result;

	# Debug section
	if ($ce->{debug_lti_grade_passback} && $ce->{debug_lti_parameters}) {
		$self->warning("The request was:\n " . $replaceResultXML);
		$self->warning("The nonce used is ${uuid_p1}__${uuid_p2}");
		$self->warning("The response is:\n " . $response->to_string);
		debug("The request was:\n " . $replaceResultXML);
		debug("The nonce used is ${uuid_p1}__${uuid_p2}");
		debug("The response is:\n " . $response->to_string);
	}

	if ($response->is_success) {
		$response->body =~ /<imsx_codeMajor>\s*(\w+)\s*<\/imsx_codeMajor>/;
		my $message = $1;
		$self->warning("result is: $message") if $ce->{debug_lti_grade_passback};
		if ($message ne 'success') {
			$self->warning("Unable to update LMS grade $sourcedid. LMS responded with message: $message")
				if $self->{post_processing_mode};
			debug("Unable to update LMS grade $sourcedid. LMS responded with message: $message");
			return 0;
		} else {
			# If we got here, we got successes from both the post and the lms.
			debug("Successfully updated LMS grade $sourcedid. LMS responded with message: $message");
		}
	} else {
		$self->warning("Unable to update LMS grade $sourcedid. Error: " . $response->message)
			if $self->{post_processing_mode};
		debug("Unable to update LMS grade $sourcedid. Error: " . $response->message);
		debug($response->body);
		return 0;
	}
	$self->warning("Success submitting grade using sourcedid: $sourcedid and score: $score")
		if $self->{post_processing_mode};
	debug("Success submitting grade using sourcedid: $sourcedid and score: $score");

	return 1;
}

1;
