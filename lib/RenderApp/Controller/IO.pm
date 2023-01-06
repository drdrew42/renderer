package RenderApp::Controller::IO;
use Mojo::Base -async_await;
use Mojo::Base 'Mojolicious::Controller';
use File::Spec::Functions qw(splitdir);
use File::Find qw(find);
use MIME::Base64 qw(decode_base64);
use Mojo::JSON qw(decode_json);
use Mojolicious::Validator;
use Math::Random::Secure qw( rand );
use Mojo::IOLoop;
use WeBWorK::Utils::Tags;

our $regex = {
  anyPg => qr/.+\.pg$/,
  allPathsPg => qr/^(:?private\/|Contrib\/|webwork-open-problem-library\/Contrib\/|Library\/|webwork-open-problem-library\/OpenProblemLibrary\/)(?!\.\.\/).*\.pg$/,
  publicOnlyPg => qr/^(:?Contrib\/|webwork-open-problem-library\/Contrib\/|Library\/|webwork-open-problem-library\/OpenProblemLibrary\/)(?!\.\.\/).*\.pg$/,
  privateOnlyPg => qr/^private\/(?!\.\.\/).*\.pg$/,
  allPaths => qr/^(:?private\/|Contrib\/|webwork-open-problem-library\/Contrib\/|Library\/|webwork-open-problem-library\/OpenProblemLibrary\/)(?!\.\.\/)/,
  publicOnly => qr/^(:?Contrib\/|webwork-open-problem-library\/Contrib\/|Library\/|webwork-open-problem-library\/OpenProblemLibrary\/)(?!\.\.\/)/,
  privateOnly => qr/^private\/(?!\.\.\/)/,
};

sub raw {
    my $c = shift;
    my $required = [];
    push @$required,
      {
        field     => 'sourceFilePath',
        checkType => 'like',
        check     => $regex->{allPathsPg},
      };
    my $validatedInput = $c->validateRequest( { required => $required } );
    return unless $validatedInput;

    my $file_path = $validatedInput->{sourceFilePath};
    my $problem   = $c->newProblem( { log => $c->log, read_path => $file_path } );
    $problem->{action} = 'fetch source';
    return $c->exception( $problem->{_message}, $problem->{status} )
      unless $problem->success();
    $c->render( text => $problem->{problem_contents} );
}

async sub writer {
    my $c         = shift;
    my $required = [];
    push @$required,
      {
        field     => 'writeFilePath',
        checkType => 'like',
        check     => $regex->{privateOnlyPg},
      };
    push @$required,
      {
        field     => 'problemSource',
      };
    my $validatedInput = $c->validateRequest( { required => $required } );
    return unless $validatedInput;
    my $source = Encode::decode("UTF-8",decode_base64( $validatedInput->{problemSource} ) );
    my $file_path = $validatedInput->{writeFilePath};

    if ( $source =~ /^\s*$/ ) {
      doBadThings( $file_path );
      return $c->render( text => $file_path );
    }

    my $problem   = $c->newProblem(
        {
            log              => $c->log,
            write_path       => $file_path,
            problem_contents => $source
        }
    );

    return $c->exception( $problem->{_message}, $problem->{status} )
      unless $problem->success();

    $c->render_later;
    my $saveSuccess = await $problem->save;

    return ( $saveSuccess ) ?
      $c->render( text => $problem->{write_path} ) :
      $c->exception( $problem->{_message}, $problem->{status} );
}

sub upload {
    my $c = shift;

    # check size
    return $c->render( text => 'File exceeded size cap.', status => 431 )
      if $c->req->is_limit_exceeded;

    my $required = [];
    my $optional = [];
    push @$required,
      {
        field     => 'path',
        checkType => 'like',
        check     => $regex->{privateOnly},
      };
    push @$optional,
      {
        field     => 'file',
        checkType => 'upload',
      };
    my $validatedInput = $c->validateRequest( { required => $required, optional => $optional } );
    return unless $validatedInput;
    my $upload = $validatedInput->{file};
    my $path   = $validatedInput->{path};

    # static images must share a folder with an existing pg file
    my $mf_path = Mojo::File->new($path);
    return $c->render( text => 'No orphaned uploads', status => 400 )
      unless ( -e $mf_path->dirname
        and -d $mf_path->dirname
        and -w $mf_path->dirname );

    $upload->move_to($mf_path);
    return $c->render( text => 'File successfully uploaded', status => 200 );
}

sub remove {
  my $c = shift;
  my $required = [];
  push @$required,
    {
      field     => 'removeFilePath',
      checkType => 'like',
      check     => $regex->{privateOnly},
    };
  my $validatedInput = $c->validateRequest( { required => $required } );
  return unless $validatedInput;

  my $file_path = $validatedInput->{removeFilePath};
  my $file = Mojo::File->new($file_path);

  return $c->render( text => 'Path does not exist', status => 404 )
    unless (-e $file);

  if (-d $file) {
    return $c->render( text => 'Directory is not empty', status => 400 )
      unless ($file->list({ dir => 1 })->size == 0);

    $file->remove_tree;
  } else {
    $file->remove;
  }

  return $c->render( text => 'Path deleted' );
}

sub clone {
  my $c = shift;
  my $required = [];
  push @$required,
    {
      field     => 'sourceFilePath',
      checkType => 'like',
      check     => $regex->{privateOnly},
    };
  push @$required,
    {
      field     => 'targetFilePath',
      checkType => 'like',
      check     => $regex->{privateOnly},
    };
  my $validatedInput = $c->validateRequest( { required => $required } );
  return unless $validatedInput;

  my $source_path = $validatedInput->{sourceFilePath};
  my $source_file = Mojo::File->new($source_path);
  my $target_path = $validatedInput->{targetFilePath};
  my $target_file = Mojo::File->new($target_path);
  
  return $c->render( text => 'source does not exist', status => 404 )
    unless (-e $source_file);

  return $c->render( text => 'target already exists', status => 400 )
    if (-e $target_file);

  # allow cloning of directories - problems with static assets
  # no recursing through directories!
  if (-d $source_file) {
    return $c->render( text => 'source does not contain clone-able files', status => 400)
      if ($source_file->list->size == 0);

    return $c->render( text => 'target must also be a directory', status => 400)
      unless ($target_path =~ m!.*/$!);
    
    $target_file->make_path;
    for ($source_file->list->each) {
      $_->copy_to($target_path . $_->basename);
    }
  } else {
    return $c->render( text => 'you may not create new directories with this method', status => 400)
      unless (-e $target_file->dirname);

    return($c->render( text => 'file extensions do not match'))
      unless ($source_file->extname eq $target_file->extname);

    $source_file->copy_to($target_file);
  }

  return $c->render( text => 'clone successful' );
}

async sub catalog {
    my $c = shift;
    my $required = [];
    my $optional = [];
    push @$required,
      {
        field     => 'basePath',
      };
    push @$optional,
      {
        field     => 'maxDepth',
        checkType => 'like',
        check     => qr/^\d+$/,
      };
    my $validatedInput = $c->validateRequest( { required => $required, optional => $optional } );
    return unless $validatedInput;
    my $root_path = $validatedInput->{basePath};
    my $depth     = $validatedInput->{maxDepth} // 2;

    $root_path =~ s!\s+|\.\./!!g;
    $root_path =~ s!^Library/!webwork-open-problem-library/OpenProblemLibrary/!;
    $root_path =~ s!^Contrib/!webwork-open-problem-library/Contrib/!;
    $root_path =~ s!^Pending/!webwork-open-problem-library/Pending/!;
    
    $root_path =~ s!/$!!; # strip trailing slashes so that Library/ and Contrib/ act like other directories

    if ( $depth == 0 || !-d $root_path ) {
        # warn($root_path) if !(-e $root_path);
        return ( -e $root_path ) ? $c->rendered(200) : $c->rendered(404);
    }

    if ( !($root_path =~ /^(:?webwork-open-problem-library\/.*|private\/.*|private)$/) ) {
        $c->log->warn("Someone is cataloguing a path outside of OPL and private! $root_path");
        return $c->rendered(403);
    }
    $c->render_later;
    my ($results, $status) = await depthSearch_p($root_path, $depth);
    $c->render( json => $results, status => $status );
}

sub depthSearch_p {
    my ( $root_path, $depth )= @_;

    my $promise = Mojo::IOLoop->subprocess->run_p(
        sub {
            # skip any hidden folders
            local $File::Find::skip_pattern = qr/^\./;
            my %all;
            my $wanted = sub {
                # measure depth relative to root_path
                ( my $rel = $File::Find::name ) =~ s!^\Q$root_path\E/?!!;
                my $path = $File::Find::name;
                $File::Find::prune = 1
                  if File::Spec::Functions::splitdir($rel) >= $depth;
                $path = $path . '/' if -d $File::Find::name;
                # only report .pg files and directories
                $all{$rel} = $path
                  if ( $rel =~ /\S/ && ( $path =~ m!.+/$! || $path =~ m!.+\.pg$! ) );
            };
            File::Find::find { wanted => $wanted, no_chdir => 1 }, $root_path;
            return \%all, 200;
        }
    )->catch(
        sub {
            warn( '-' x 10 . "PROMISE REJECTED" . '-' x 10 );
            return {
                message    => 'Error occurred during catalog: ' . shift,
                status     => 'Internal Server Failure',
                statusCode => 500
            }, 500;
        }
    );
    return $promise;
}

async sub search {
    my $c = shift;

    my $required = [];
    push @$required,
      {
        field     => 'basePath',
        checkType => 'like',
        check     => qr/.+\.pg$/,
      };
    my $validatedInput = $c->validateRequest( { required => $required } );
    return unless $validatedInput;
    my $target = $validatedInput->{basePath};
    my @targetArray = split /\//, $target;

    my $sources = [
        'private/',
        'webwork-open-problem-library/OpenProblemLibrary/',
        'webwork-open-problem-library/Contrib/'
    ];
    $c->render_later;
    my ($results, $status) = await rankedSearch_p($sources, \@targetArray);
    return $c->render( json => $results, status => $status );
}

sub rankedSearch_p {
    my $sources_ref = shift;
    my @sources = @$sources_ref;
    my $targetArray_ref = shift;
    my @targetArray = @$targetArray_ref;
    my $searchPromise = Mojo::IOLoop->subprocess->run_p(
        sub {
            local $File::Find::skip_pattern = qr/^\./;    #skip any hidden folders
            my %found;
            my $wanted = sub {
                my $path       = $File::Find::name;
                my %pathHash   = map { $_ => 1 } split /\//, $path;
                my $matchCount = 0;

                # don't continue unless the actual pg file matches...
                unless ( defined( $pathHash{ $targetArray[-1] } ) ) {
                    return;
                }

                # when we have a matching filename, measure how much of the requested target is a match
                for my $piece (@targetArray) {
                    $matchCount++
                      if ( defined( $pathHash{$piece} )
                        || ( $piece eq 'Library' && defined( $pathHash{'OpenProblemLibrary'} ) )
                      );
                }
                # we only get here if the filename matches
                $found{$path} = $matchCount / ( $#targetArray + 1 );
            };
            for my $source (@sources) {
                File::Find::find { wanted => $wanted, no_chdir => 1 }, $source;
            }
            return \%found, 200;
        }
    )->catch(
        sub {
            warn( '*' x 10 . "PROMISE REJECTED" . '*' x 10 );
            return {
                message    => 'Error occurred during file search: ' . shift,
                status     => 'Internal Server Failure',
                statusCode => 500
            }, 500;
        }
    );
    return $searchPromise;
}

async sub findNewVersion {
	my $c = shift;
    my $required = [];
    my $optional = [];
    push @$required,
      {
        field     => 'sourceFilePath',
        checkType => 'like',
        check     =>  $regex->{allPathsPg},
      };
    push @$required,
      {
        field     => 'avoidSeeds',
        checkType => 'like',
        check     => qr/^[\d\s,]+$/,
      };
    push @$optional,
      {
        field     => 'maxIterations',
        checkType => 'like',
        check     => qr/^\d+$/,
      };
    my $validatedInput = $c->validateRequest( { required => $required, optional => $optional } );
    return unless $validatedInput;

	my $filePath = $validatedInput->{sourceFilePath};
	my $seedString = $validatedInput->{avoidSeeds};
	my $maxIterations = $c->param('maxIterations') || 5;
    $seedString =~ s/\s//g;
	my @avoidSeeds = split(',', $seedString);

	my $avoidProblems = {};
  $c->render_later;
	for my $seed (@avoidSeeds) {
		my $problem = $c->newProblem( {log=>$c->log, read_path=>$filePath, random_seed=>$seed} );
    my $renderedProblem = await $problem->render( {} );
    next unless ($problem->success());
		$avoidProblems->{$seed} = decode_json( $renderedProblem );
	}

	my ($newSeed, $newProblem);
    my $newFailed = [];
	for my $i (1..$maxIterations) {
		do { 
        $newSeed = 1 + int rand( 999999 );
		} until (!exists($avoidProblems->{$newSeed}));

    my $newProblemObj = $c->newProblem( { log => $c->log, read_path => $filePath, random_seed => $newSeed } );
    my $newProblemJson = await $newProblemObj->render( {} );
    next unless ($newProblemObj->success());
    $newProblem = decode_json( $newProblemJson );

    if ( _isNewVersion( $newProblem, $avoidProblems ) ) {
        last;
    } else {
        push @$newFailed, $newSeed;
        $newProblem = undef;
    }
	}

  if ( $newProblem ) {
      return $c->respond_to(
          html => { text => $newProblem->{renderedHTML} },
          # respond to format: json
          json => { 
              # with a json from an anon hashRef
              json => {
                  problem => $newProblem,
                  problemSeed => $newSeed,
              }
          }
      );
  } else {
      return $c->render(
          json => {
              statusCode => 404,
              error    => "Not Found",
              message  => "Could not find a different version",
              data     => $newFailed
          },
          status => 404
      );
  }
}

async sub findUniqueSeeds {
	my $c = shift;
    my $required = [];
    my $optional = [];
    push @$required,
      {
        field     => 'sourceFilePath',
        checkType => 'like',
        check     =>  $regex->{allPathsPg},
      };
    push @$required,
      {
        field     => 'numberOfSeeds',
        checkType => 'like',
        check     => qr/^[\d\s,]+$/,
      };
    push @$optional,
      {
        field     => 'maxIterations',
        checkType => 'like',
        check     => qr/^\d+$/,
      };
    my $validatedInput = $c->validateRequest( { required => $required, optional => $optional } );
    return unless $validatedInput;

	my $filePath = $validatedInput->{sourceFilePath};
	my $numberOfSeeds = $validatedInput->{numberOfSeeds};
	my $maxIterations = $c->param('maxIterations') || 2 * $numberOfSeeds;

	my $uniqueProblems = {};
  my $triedSeeds = {};

	my ($newSeed, $newProblem);
  my $newFailed = [];
  $c->render_later;

	for my $i (1..$maxIterations) {
		do {
        $newSeed = 1 + int rand(999999);
		} until (!exists($triedSeeds->{$newSeed}));
        my $newProblemObj = $c->newProblem( { log => $c->log, read_path => $filePath, random_seed => $newSeed } );
        my $newProblemJson = await $newProblemObj->render( {} );
        next unless ($newProblemObj->success());
        $newProblem = decode_json( $newProblemJson );

        if ( _isNewVersion( $newProblem, $uniqueProblems ) ) {
            $uniqueProblems->{$newSeed} = $newProblem;
            if (scalar(keys %$uniqueProblems) >= $numberOfSeeds) {
                last;
            }
        } else {
            push @$newFailed, $newSeed;
        }
	}

  my @returnKeys = keys %$uniqueProblems;
  if ( scalar @returnKeys >= $numberOfSeeds ) {
      return $c->render(
          json => { uniqueKeys => \@returnKeys }
      );
  } else {
      return $c->render(
          json => {
              statusCode => 404,
              error    => "Not Found",
              message  => "Could not find $numberOfSeeds different versions.",
              data     => {
                  uniqueKeys => \@returnKeys,
                  duplicates => $newFailed,
              }
          },
          status => 404
      );
  }
}

sub _isNewVersion {
	my $newProblem = shift;
	my $avoidProblems = shift;
	my $isNew = 0;

    return 1 unless ( keys %$avoidProblems );

	for my $avoidProblemKey (keys %$avoidProblems) {
    my $newHTML = $newProblem->{renderedHTML};
    # rendered HTML needs to have this removed...
    $newHTML =~ s/<input type="hidden" name="problemSeed" value = "\d+">//g;
    my $avoidHTML = $avoidProblems->{$avoidProblemKey}->{renderedHTML};
    $avoidHTML =~ s/<input type="hidden" name="problemSeed" value = "\d+">//g;
		if ($newHTML ne $avoidHTML) {
			$isNew = 1;
			last;
		}
	}

	return $isNew;
}

async sub setTags {
  my $c = shift;
  my $incomingTags = $c->req->params->to_hash;
  
  # if DESCRIPTION is only one line, params will not instantiate DESCRIPTION as an array...
  $incomingTags->{DESCRIPTION} = [$incomingTags->{DESCRIPTION}] unless (ref($incomingTags->{DESCRIPTION}) =~ /ARRAY/);
  # the same holds for keywords
  $incomingTags->{keywords} = [$incomingTags->{keywords}] unless (ref($incomingTags->{keywords}) =~ /ARRAY/);

  my $problem = $c->newProblem( { log => $c->log, read_path => $incomingTags->{file} } );

  # wrap the get/update/write tags in a promise
  my $tags = WeBWorK::Utils::Tags->new($incomingTags->{file});
  foreach my $key (keys %$incomingTags) {
    # printf "SETTING: [%15s] => %s\n", $key, $incomingTags->{$key};
    $tags->{$key} = $incomingTags->{$key};
  }
  $tags->write();

  # return tags + pre-DOCUMENT() header
  $problem->load;
  my $header = $1 if ($problem->{problem_contents} =~ /(.*?)DOCUMENT\(\);/s);
  $header ||= $problem->{problem_contents}; # pointer files have no DOCUMENT calls -- others?
  my $return_object = { 
    tags => $tags,
    raw_metadata_text => $header 
  };
  return $c->render(json => $return_object, status => 200);
}

sub validate {
    my $c = shift;
    my $options = shift;
    my $required = $options->{required} // [];
    my $optional = $options->{optional} // [];

    my $validator = Mojolicious::Validator->new;
    my $v = $validator->validation;

    # file uploads are stripped from incoming params 
    my $inputHash = $c->req->params->to_hash;
    # add them individually from the array of uploads
    for my $upload (@{$c->req->uploads}) {
      $inputHash->{$upload->name} = $upload;
    }
    $v->input($inputHash);

    for my $req (@$required) {
      if (exists $req->{checkType}) {
        $v->required( $req->{field} )->check( $req->{checkType}, $req->{check} );
      } else {
        $v->required( $req->{field} );
      }
    }
    for my $req (@$optional) {
      if (exists $req->{checkType}) {
        $v->optional( $req->{field} )->check( $req->{checkType}, $req->{check} );
      } else {
        $v->optional( $req->{field} );
      }
    }

    if ($v->has_error) {
        $c->log->error( "Request data failed to validate: " . join( ', ', @{ $v->failed } ) );
        my $errMessage = [];
        for my $field (@{$v->failed}) {
            my ($check, $result, @args) = @{$v->error($field)};
            my $errString = "Field '$field' failed to validate '$check' check";
            push @$errMessage, $errString;
        }
        $c->render(
            json => {
                statusCode => 412,
                error      => "Precondition Failed",
                message    => $errMessage,
                data       => {
                    failed => $v->failed,
                    passed => $v->passed,
                }
            },
            status => 412
        );
        return undef;
    } else {
        return $v->output;
    }
}

sub doBadThings {
  my $path = Mojo::File->new(shift);
  $path->dirname->make_path;
  $path->touch;
  return;
}

1;
