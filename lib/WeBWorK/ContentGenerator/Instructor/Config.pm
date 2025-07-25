package WeBWorK::ContentGenerator::Instructor::Config;
use Mojo::Base 'WeBWorK::ContentGenerator', -signatures;

=head1 NAME

WeBWorK::ContentGenerator::Instructor::Config - Config

=cut

use XML::LibXML;

use WeBWorK::CourseEnvironment;
use WeBWorK::ConfigObject::text;
use WeBWorK::ConfigObject::timezone;
use WeBWorK::ConfigObject::time;
use WeBWorK::ConfigObject::number;
use WeBWorK::ConfigObject::boolean;
use WeBWorK::ConfigObject::permission;
use WeBWorK::ConfigObject::permission_checkboxlist;
use WeBWorK::ConfigObject::list;
use WeBWorK::ConfigObject::checkboxlist;
use WeBWorK::ConfigObject::popuplist;
use WeBWorK::ConfigObject::setting;
use WeBWorK::ConfigObject::lms_context_id;
use WeBWorK::ConfigValues qw(getConfigValues);

# Write contents to outputFilePath and return error messages if any.
sub writeFile ($outputFilePath, $contents) {
	if (open my $OUTPUTFILE, '>:encoding(UTF-8)', $outputFilePath) {
		print $OUTPUTFILE $contents;
		close $OUTPUTFILE;
		return 1;
	}
	return 0;
}

# Make a new config object from data
sub objectify ($c, $data) {
	return "WeBWorK::ConfigObject::$data->{type}"->new($data, $c);
}

sub pre_header_initialize ($c) {
	$c->stash->{configValues} = [];

	return unless $c->authz->hasPermissions($c->param('user'), 'modify_problem_sets');

	# Record status messages carried over if this is a redirect
	$c->addmessage($c->authen->flash('status_message') || '');

	my $ce = $c->ce;
	$c->stash->{configValues} = getConfigValues($ce);

	if ($c->param('make_changes')) {
		# Get a copy of the course environment which does not have simple.conf loaded
		my $ce2 = WeBWorK::CourseEnvironment->new({
			courseName          => $ce->{courseName},
			web_config_filename => 'noSuchFilePlease'
		});

		my $fileoutput = <<~ 'END_SIMPLE_CONF_HEADER';
			#!perl
			# This file is automatically generated by WeBWorK's web-based
			# configuration module.  Do not make changes directly to this
			# file.  It will be overwritten the next time configuration
			# changes are saved.

			END_SIMPLE_CONF_HEADER

		# Write all settings that are different from the default to the simple configuration file.
		for my $configSection (@{ $c->stash->{configValues} }) {
			my @configSectionArray = @$configSection;
			shift @configSectionArray;
			for my $con (@configSectionArray) {
				my $conobject = $c->objectify($con);
				if (defined $ce->{permissionLevels}{"change_config_$con->{var}"}
					&& !$c->authz->hasPermissions($c->param('user'), "change_config_$con->{var}"))
				{
					# The user does not have permission to change this configuration value.
					# So use the current course environment value.
					$fileoutput .= $conobject->save_string($conobject->get_value($ce2), 1);
				} else {
					$fileoutput .= $conobject->save_string($conobject->get_value($ce2));
				}
			}
		}

		if (writeFile("$ce->{courseDirs}{root}/simple.conf", $fileoutput)) {
			$c->addgoodmessage($c->maketext('Changes saved.'));

			# Redirect back to the instructor config page after saving settings.  After the redirect the now saved
			# changes will take effect.  This gives the appearance that settings take effect immediately after saving.
			$c->authen->flash(status_message => $c->{status_message}->join(''));
			$c->reply_with_redirect($c->systemLink($c->url_for('instructor_config'), params => ['current_tab']));
		} else {
			$c->addbadmessage(
				$c->c(
					$c->tag('div', $c->maketext('Unable to open the "~[COURSEROOT~]/simple.conf" file.')),
					$c->tag(
						'div',
						$c->maketext(
							'Contact the site administrator to ensure that the permissions '
								. 'are set so that the web server can write to this file.'
						)
					)
				)->join('')
			);
		}
	}

	return;
}

1;
