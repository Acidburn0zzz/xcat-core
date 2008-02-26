# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::rhel;
use Storable qw(dclone);
use Sys::Syslog;
use xCAT::Table;
use xCAT::Template;
use xCAT::Postage;
use Data::Dumper;
use Getopt::Long;
Getopt::Long::Configure("bundling");
Getopt::Long::Configure("pass_through");
use File::Path;
use File::Copy;

my %discids = (
  "1170973598.629055" => "rhelc5",
  "1170978545.752040" => "rhels5",
  "1192660014.052098" => "rhels5.1",
  "1192663619.181374" => "rhels5.1",
  );

sub handled_commands {
  return {
    copycd => "rhel",
    mkinstall => "nodetype:os=rh.*",
    mknetboot => "nodetype:os=rh.*"
  }
}
  
sub process_request {
  my $request = shift;
  my $callback = shift;
  my $doreq = shift;
  my $distname = undef;
  my $arch = undef;
  my $path = undef;
  if ($request->{command}->[0] eq 'copycd') { 
    return copycd($request,$callback,$doreq);
  } elsif ($request->{command}->[0] eq 'mkinstall') {
    return mkinstall($request,$callback,$doreq);
  } elsif ($request->{command}->[0] eq 'mknetboot') {
    return mknetboot($request,$callback,$doreq);
  }
}

sub mknetboot {
    my $req = shift;
    my $callback = shift;
    my $doreq = shift;
    my $tftpdir = "/tftpboot";
    my $nodes = @{$request->{node}};
    my @args=@{$req->{arg}};
    my @nodes = @{$req->{node}};
    my $ostab = xCAT::Table->new('nodetype');
    my $sitetab = xCAT::Table->new('site');
    (my $sent) = $sitetab->getAttribs({key=>master},value);
    my $imgsrv;
    if ($sent and $sent->{value}) {
       $imgsrv = $sent->{value};
    }
    my $installroot;
    $installroot="/install";
    if ($sitetab) { 
        (my $ref) = $sitetab->getAttribs({key=>installdir},value);
        print Dumper($ref);
        if ($ref and $ref->{value}) {
            $installroot = $ref->{value};
        }
    }
    foreach $node (@nodes) {
        my $ent = $ostab->getNodeAttribs($node,['os','arch','profile']);
        unless ($ent->{os} and $ent->{arch} and $ent->{profile}) {
            $callback->({error=>["Insufficient nodetype entry for $node"],errorcode=>[1]});
            next;
        }
        my $osver = $ent->{os};
        my $arch = $ent->{arch};
        my $profile = $ent->{profile};
        my $suffix = 'gz';
        if (-r "/$installroot/netboot/$osver/$arch/$profile/rootimg.sfs") {
           $suffix = 'sfs';
        }
        unless ((-r "/$installroot/netboot/$osver/$arch/$profile/rootimg.gz" or 
                -r "/$installroot/netboot/$osver/$arch/$profile/rootimg.sfs") and
                -r "/$installroot/netboot/$osver/$arch/$profile/kernel" and
                -r "/$installroot/netboot/$osver/$arch/$profile/initrd.gz") {
               $callback->({error=>["No packed image for platform $osver, architecture $arch, and profile $profile, please run packimage (i.e.  packimage -o $osver -p $profile -a $arch"],errorcode=>[1]});
               next;
        }
        mkpath("/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
        #TODO: only copy if newer...
        copy("/$installroot/netboot/$osver/$arch/$profile/kernel","/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
        copy("/$installroot/netboot/$osver/$arch/$profile/initrd.gz","/$tftpdir/xcat/netboot/$osver/$arch/$profile/");
        unless (-r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/kernel" and -r "/$tftpdir/xcat/netboot/$osver/$arch/$profile/initrd.gz") {
           $callback->({error=>["Copying to /$tftpdir/xcat/netboot/$osver/$arch/$profile failed"],errorcode=>[1]});
           next;
        }
        my $restab = xCAT::Table->new('noderes');
        my $hmtab = xCAT::Table->new('nodehm');
        my $ent = $restab->getNodeAttribs($node,['serialport','primarynic']);
        my $ient = $restab->getNodeAttribs($node,['servicenode']);
        my $ipfn = xCAT::Utils->my_ip_facing($node);
        if ($ient and $ient->{servicenode}) { #Servicenode attribute overrides
           $imgsrv = $ient->{servicenode};
        } elsif ($ipfn) {
           $imgsrv = $ipfn; #guessing self is second best
        } # resort to master value in site table only if not local to node...
        unless ($imgsrv) {
           $callback->({error=>["Unable to determine or reasonably guess the image server for $node"],errorcode=>[1]});
           next;
        }
        my $kcmdline = "imgurl=http://$imgsrv/install/netboot/$osver/$arch/$profile/rootimg.$suffix ";
        if (defined $ent->{serialport}) {
         my $sent = $hmtab->getNodeAttribs($node,['serialspeed','serialflow']);
         unless ($sent->{serialspeed}) {
            $callback->({error=>["serialport defined, but no serialspeed for $node in nodehm table"],errorcode=>[1]});
            next;
         }
         $kcmdline .= "console=ttyS".$ent->{serialport}.",".$sent->{serialspeed};
         if ($sent->{serialflow} =~ /(hard|tcs|ctsrts)/) {
            $kcmdline .= "n8r";
          }
        }
        $restab->setNodeAttribs($node,{
           kernel=>"xcat/netboot/$osver/$arch/$profile/kernel",
           initrd=>"xcat/netboot/$osver/$arch/$profile/initrd.gz",
           kcmdline=>$kcmdline
        });
    }
}

sub mkinstall {
  my $request = shift;
  my $callback = shift;
  my $doreq = shift;
  my @nodes = @{$request->{node}};
  my $node;
  my $ostab = xCAT::Table->new('nodetype');
  my %doneimgs;
  foreach $node (@nodes) {
    my $osinst;
    my $ent = $ostab->getNodeAttribs($node,['profile','os','arch']);
    unless ($ent->{os} and $ent->{arch} and $ent->{profile}) {
      $callback->({error=>["No profile defined in nodetype for $node"],errorcode=>[1]});
      next; #No profile
    }
    my $os = $ent->{os};
    my $arch = $ent->{arch};
    my $profile = $ent->{profile};
    unless (-r $::XCATROOT."/share/xcat/install/rh/".$ent->{profile}.".tmpl" or 
            -r $::XCATROOT."/share/xcat/install/rh/$profile.$arch.tmpl" or
            -r $::XCATROOT."/share/xcat/install/rh/$profile.$os.tmpl" or
            -r $::XCATROOT."/share/xcat/install/rh/$profile.$os.$arch.tmpl") {
      $callback->({error=>["No kickstart template exists for ".$ent->{profile}],errorcode=>[1]});
      next;
    }
    #Call the Template class to do substitution to produce a kickstart file in the autoinst dir
    
    if ( -r $::XCATROOT."/share/xcat/install/rh/$profile.$os.$arch.tmpl" ) { 
       xCAT::Template->subvars($::XCATROOT."/share/xcat/install/rh/$profile.$os.$arch.tmpl","/install/autoinst/".$node,$node);
    } elsif ( -r $::XCATROOT."/share/xcat/install/rh/$profile.$arch.tmpl" ) { 
       xCAT::Template->subvars($::XCATROOT."/share/xcat/install/rh/$profile.$arch.tmpl","/install/autoinst/".$node,$node);
    } elsif ( -r $::XCATROOT."/share/xcat/install/rh/$profile.$os.tmpl" ) { 
       xCAT::Template->subvars($::XCATROOT."/share/xcat/install/rh/$profile.$os.tmpl","/install/autoinst/".$node,$node);
    } else {
       xCAT::Template->subvars($::XCATROOT."/share/xcat/install/rh/".$ent->{profile}.".tmpl","/install/autoinst/".$node,$node);
    }
    mkpath "/install/postscripts/";
    xCAT::Postage->writescript($node,"/install/postscripts/".$node);
    if (($arch =~ /x86/ and 
      (-r "/install/$os/$arch/images/pxeboot/vmlinuz" and -r  "/install/$os/$arch/images/pxeboot/initrd.img")) 
      or $arch =~ /ppc/ and 
      (-r "/install/$os/$arch/ppc/ppc64/vmlinuz" and -r "/install/$os/$arch/ppc/ppc64/ramdisk.image.gz")) {
      unless ($doneimgs{"$os|$arch"}) {
      #TODO: driver slipstream, targetted for network.
        mkpath("/tftpboot/xcat/$os/$arch");
        if ($arch =~ /x86/) {
           copy("/install/$os/$arch/images/pxeboot/vmlinuz","/tftpboot/xcat/$os/$arch/");
           copy("/install/$os/$arch/images/pxeboot/initrd.img","/tftpboot/xcat/$os/$arch/");
        } elsif ($arch =~ /ppc/) {
           copy("/install/$os/$arch/ppc/ppc64/vmlinuz","/tftpboot/xcat/$os/$arch/");
           copy("/install/$os/$arch/ppc/ppc64/ramdisk.image.gz","/tftpboot/xcat/$os/$arch/initrd.img");
        } else {
            $callback->({error=>["Plugin doesn't know how to handle architecture $arch"],errorcode=>[1]});
            next;
        }
        $doneimgs{"$os|$arch"}=1;
      }
      #We have a shot...
      my $restab = xCAT::Table->new('noderes');
      my $ent = $restab->getNodeAttribs($node,['nfsserver','serialport','primarynic','installnic']);
      my $hmtab = xCAT::Table->new('nodehm');
      my $sent = $hmtab->getNodeAttribs($node,['serialspeed','serialflow']);
      unless ($ent and $ent->{nfsserver}) {
        $callback->({error=>["No noderes.nfsserver defined for ".$node],errorcode=>[1]});
        next;
      }
      my $kcmdline="nofb utf8 ks=http://".$ent->{nfsserver}."/install/autoinst/".$node;
      if ($ent->{installnic}) {
        $kcmdline.=" ksdevice=".$ent->{installnic};
      } elsif ($ent->{primarynic}) { 
        $kcmdline.=" ksdevice=".$ent->{primarynic};
      } else {
        $kcmdline .= " ksdevice=eth0";
      }

      #TODO: dd=<url> for driver disks
      if (defined $ent->{serialport}) {
        unless ($sent->{serialspeed}) {
          $callback->({error=>["serialport defined, but no serialspeed for $node in nodehm table"],errorcode=>[1]});
          next;
        }
        $kcmdline.=" console=ttyS".$ent->{serialport}.",".$sent->{serialspeed};
        if ($sent->{serialflow} =~ /(ctsrts|cts|hard)/) {
          $kcmdline .= "n8r";
        }
      }
      $kcmdline .= " noipv6";
      
      $restab->setNodeAttribs($node,{
        kernel=>"xcat/$os/$arch/vmlinuz",
        initrd=>"xcat/$os/$arch/initrd.img",
        kcmdline=>$kcmdline
      });
    } else {
        $callback->({error=>["Install image not found in /install/$os/$arch"],errorcode=>[1]});
    }
  }
}

sub copycd {
  my $request = shift;
  my $callback = shift;
  my $doreq = shift;
  my $installroot;
  my $sitetab = xCAT::Table->new('site');
  if ($sitetab) { 
    (my $ref) = $sitetab->getAttribs({key=>installdir},value);
    print Dumper($ref);
    if ($ref and $ref->{value}) {
      $installroot = $ref->{value};
    }
  }

  @ARGV= @{$request->{arg}};
  GetOptions(
    'n=s' => \$distname,
    'a=s' => \$arch,
    'p=s' => \$path
  );
  unless ($path) {
    #this plugin needs $path...
    return;
  }
  if ($distname and $distname !~ /^rh/) {
    #If they say to call it something other than RH, give up?
    return;
  }
  unless (-r $path."/.discinfo") {
    return;
  }
  my $dinfo;
  open($dinfo,$path."/.discinfo");
  my $did = <$dinfo>;
  chomp($did);
  my $desc = <$dinfo>;
  chomp($desc);
  my $darch = <$dinfo>;
  chomp($darch);
  if ($darch and $darch =~ /i.86/) {
    $darch = "x86";
  }
  close($dinfo);
  if ($discids{$did}) {
      unless ($distname) {
          $distname = $discids{$did};
      }
  }
  if ($desc =~ /^Red Hat Enterprise Linux Client 5$/) {
    unless ($distname) {
      $distname = "rhelc5";
    }
  } elsif ($desc =~ /^Red Hat Enterprise Linux Server 5$/) {
    unless ($distname) {
      $distname = "rhels5";
    }
  }
  print $desc;
  unless ($distname) {
    return; #Do nothing, not ours..
  }
  if ($darch) {
    unless ($arch) { 
      $arch = $darch;
    }
    if ($arch and $arch ne $darch) {
      $callback->({error=>"Requested RedHat architecture $arch, but media is $darch"});
      return;
    }
    if ($arch =~ /ppc/) { $arch = "ppc64" };
  }
  %{$request} = (); #clear request we've got it.

  $callback->({data=>"Copying media to $installroot/$distname/$arch/"});
  my $omask=umask 0022;
  mkpath("$installroot/$distname/$arch");
  umask $omask;
  my $rc = system("cd $path; find . | cpio -dump $installroot/$distname/$arch");
  chmod 0755,"$installroot/$distname/$arch";
  xCAT::Yum->localize_yumrepo($installroot,$distname,$arch);
  if ($rc != 0) {
    $callback->({error=>"Media copy operation failed, status $rc"});
  } else {
    $callback->({data=>"Media copy operation successful"});
  }
}

1;
