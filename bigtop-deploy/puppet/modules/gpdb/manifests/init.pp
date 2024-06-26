# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

class gpdb {

  class deploy($roles) {
    if ("gpdb-master" in $roles or "gpdb-segment" in $roles) {
      include gpdb::common
    }
  }

  class common($nodes, $gp_home, $db_base_dir, $master_db_port, $segment_db_port_prefix) {

    include stdlib

    class { 'gpdb::common::install_packages': }

    class { 'gpdb::common::gpadmin_user':}

    class { 'gpdb::common::prepare_file_structure':
      base_dir => "$db_base_dir",
      require  => Class['gpdb::common::gpadmin_user']
    }

    class { 'gpdb::common::prepare_db_dirs':
      base_dir            => "$db_base_dir",
      nodes               => $nodes,
      gp_home             => $gp_home,
      master_port         => $master_db_port,
      segment_port_prefix => $segment_db_port_prefix,
      require             => [Class['gpdb::common::prepare_file_structure'], Class['gpdb::common::install_packages']]
    }

    class { 'gpdb::common::start_master_node':
      base_dir            => "$db_base_dir",
      nodes               => $nodes,
      gp_home             => $gp_home,
      master_port         => $master_db_port,
      segment_port_prefix => $segment_db_port_prefix,
      require             => Class['gpdb::common::prepare_db_dirs']
    }

    class gpadmin_user{
      group { 'gpadmin':
        ensure => 'present',
      }
      user { 'gpadmin':
        ensure            => 'present',
        system            => false,
        managehome        => true,
        groups            => 'gpadmin',
        shell             => '/bin/bash',
      }
    }

    class install_packages{
      package { ["gpdb"]:
        ensure => latest,
      }
    }

    class prepare_file_structure($base_dir = undef){
      file { "$base_dir":
        ensure => 'directory',
        owner  => 'gpadmin',
        group  => 'gpadmin',
      }
      file { "$base_dir/master":
        ensure => 'directory',
        owner  => 'gpadmin',
        group  => 'gpadmin',
      }
      file { "$base_dir/primary":
        ensure => 'directory',
        owner  => 'gpadmin',
        group  => 'gpadmin',
      }
    }

    class prepare_db_dirs($nodes = undef, $base_dir = undef, $gp_home = undef, $master_port = undef, $segment_port_prefix = undef){
      file { '/home/gpadmin/init-db.sh':
        content => template('gpdb/init-db.sh'),
        require => [
          File["$base_dir/primary"],
          File["$base_dir/master"]],
        owner   => 'gpadmin',
        group   => 'gpadmin',
        mode    => '0700',
      }
      file { '/home/gpadmin/stop-db.sh':
        content => template('gpdb/stop-db.sh'),
        owner   => 'gpadmin',
        group   => 'gpadmin',
        mode    => '0700',
      }
      each($nodes) |$index, $value| {
        notice($value)
        if ($::fqdn == $value) {
          $dbid = $index+1
          $content = $index-1
          $hostname = $value
          $segment_nodes_count=size($nodes)-1
          if ($dbid == 1){
            $port = $master_port
            $db_sub_dir = "master"
            $m_options = "master"
            $x_options = "-x 0 -E"
            $z_options = "$segment_nodes_count"
          } else{
            $port = "$segment_port_prefix${content}"
            $db_sub_dir = "primary"
            $m_options = "mirrorless"
            $x_options = ""
            $z_options = "$segment_nodes_count"
          }
          $db_dir = "$base_dir/${db_sub_dir}/gpseg${content}"
          exec { "create_master_db${db_dir}":
            command => "init-db.sh $db_dir",
            require => [File["/home/gpadmin/init-db.sh"]],
            path    => '/home/gpadmin',
            user    => 'gpadmin',
          }
          file_line { "allow all host connection${db_dir}":
            path    => "${db_dir}/pg_hba.conf",
            line    => 'host all all 0.0.0.0/0 trust',
            require => [Exec["create_master_db${db_dir}"]],
          }
          file_line { "add 1 conf${db_dir}":
            path    => "${db_dir}/postgresql.conf",
            line    => 'log_statement=all',
            require => [Exec["create_master_db${db_dir}"]],
          }
          file_line { "add 2 conf${db_dir}":
            path    => "${db_dir}/postgresql.conf",
            line    => 'max_wal_size=384MB',
            require => [Exec["create_master_db${db_dir}"]],
          }
          file_line { "add 3 conf${db_dir}":
            path    => "${db_dir}/postgresql.conf",
            line    => "port=${port}",
            require => [Exec["create_master_db${db_dir}"]],
          }
          file_line { "add 4 conf${db_dir}":
            path    => "${db_dir}/postgresql.conf",
            line    => 'logging_collector = off',
            require => [Exec["create_master_db${db_dir}"]],
          }
          file { "${db_dir}/gp_dbid":
            content => template('gpdb/gp_dbid'),
            require => [Exec["create_master_db${db_dir}"]],
            owner   => 'gpadmin',
            group   => 'gpadmin',
            mode    => '0700',
          }
          file { "${db_dir}/gpssh.conf":
            content => template('gpdb/gpssh.conf'),
            require => [Exec["create_master_db${db_dir}"]],
            owner   => 'gpadmin',
            group   => 'gpadmin',
            mode    => '0700',
          }
        }
      }
    }


    class start_master_node($nodes = undef, $base_dir = undef, $gp_home = undef, $master_port = undef, $segment_port_prefix = undef){
      if ($::fqdn == $nodes[0]) {
        notice("must make admin")
        file { '/home/gpadmin/start-master-db-in-admin-mode.sh':
          content => template('gpdb/start-master-db-in-admin-mode.sh'),
          require => [Exec["create_master_db$base_dir/master/gpseg-1"]],
          owner   => 'gpadmin',
          group   => 'gpadmin',
          mode    => '0700',
        }
        file { '/home/gpadmin/test-master-db.sh':
          content => template('gpdb/test-master-db.sh'),
          require => [Exec["create_master_db$base_dir/master/gpseg-1"]],
          owner   => 'gpadmin',
          group   => 'gpadmin',
          mode    => '0700',
        }
        exec { 'start-master-db-in-admin-mode':
          command => "start-master-db-in-admin-mode.sh $base_dir/master/gpseg-1",
          path    => '/home/gpadmin',
          user    => 'gpadmin',
          require => [
            Exec["create_master_db$base_dir/master/gpseg-1"],
            File['/home/gpadmin/start-master-db-in-admin-mode.sh']
          ],
        }
        file { '/home/gpadmin/creat-new-table.sh':
          content => template('gpdb/creat-new-table.sh'),
          require => [Exec["start-master-db-in-admin-mode"]],
          owner   => 'gpadmin',
          group   => 'gpadmin',
          mode    => '0700',
        }
        file { '/home/gpadmin/insert-to-new-table.sh':
          content => template('gpdb/insert-to-new-table.sh'),
          require => [Exec["start-master-db-in-admin-mode"]],
          owner   => 'gpadmin',
          group   => 'gpadmin',
          mode    => '0700',
        }
        exec { "creat-new-table":
          environment => ["PGOPTIONS=-c gp_session_role=utility"],
          command     => "creat-new-table.sh",
          path        => '/home/gpadmin',
          user        => 'gpadmin',
          require     => [
            File["/home/gpadmin/creat-new-table.sh"],
            Exec['start-master-db-in-admin-mode'],
          ],
        }
        exec { "insert-to-new-table":
          environment => ["PGOPTIONS=-c gp_session_role=utility"],
          command     => "insert-to-new-table.sh",
          path        => '/home/gpadmin',
          user        => 'gpadmin',
          require     => [
            File["/home/gpadmin/insert-to-new-table.sh"],
            Exec['creat-new-table'],
          ],
        }
      }
    }
  }
}
