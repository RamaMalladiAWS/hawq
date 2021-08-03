#!/bin/sh

# parse parameters
usage() { echo "Usage: $0 [-s <3.3.x.x|2.4.0.0|2.4.0.1>] [-t <4.0.0.0>]" ; exit 1; }

while getopts ":s:t:" opt; do
    case "${opt}" in
        s)
            source_version=${OPTARG}
            if [[ "$source_version" =~ 3\.3\.[0-9]\.[0-9] || "$source_version" == "2.4.0.0" || "$source_version" == "2.4.0.1" ]];then
                echo "Input source version is $source_version."
            else
                usage
            fi
            ;;
        t)
            target_version=${OPTARG}
            if [[ "$target_version" == "4.0.0.0" ]];then
                echo "Target source version is $target_version"
            else
                usage
            fi
            ;;
        *)
            usage
            ;;
    esac
done

shift $((OPTIND-1))

if [ -z "${source_version}" ] || [ -z "${target_version}" ]; then
    usage
fi

if [[ $source_version == "2.4.0.0" || $source_version == "2.4.0.1" ]]; then
    upgrade_total=true
else
    upgrade_total=false
fi

check_error() {
    if [[ $? -ne 0 ]];then
        echo "Failed to $1."
        exit 1
    fi
    if [[ -n $2 && $2 -ne 0 ]];then
        echo "Failed to $1. Error info in output file."
        exit 1
    fi
}

# check environment
if [[ -z $GPHOME ]];then
    echo "Environment variable GPHOME is not set."
    exit 1
fi
source $GPHOME/greenplum_path.sh

# check master version
version_str=`hawq --version`
check_error "get hawq version on master"
version=`echo "$version_str"| awk -F '[ ]' '{print $3}'`
if [[ "$version" != "$target_version" ]];then
    echo "Hawq version:$version is not same with target version:$target_version in master"
    exit 1;
fi
echo "Upgrade begin, you can find logs of each module in folder $HOME/hawqAdminLogs/upgrade"

MASTER_HOST=`cat $GPHOME/etc/hawq-site.xml | grep -A 1 'hawq_master_address_host' | tail -n 1 | awk -F '[>]' '{print $2}'|awk -F '[<]' '{print $1}'`
MASTER_PORT=`cat $GPHOME/etc/hawq-site.xml | grep -A 1 'hawq_master_address_port' | tail -n 1 | awk -F '[>]' '{print $2}'|awk -F '[<]' '{print $1}'`
SEGMENT_PORT=`cat $GPHOME/etc/hawq-site.xml | grep -A 1 'hawq_segment_address_port' | tail -n 1 | awk -F '[>]' '{print $2}'|awk -F '[<]' '{print $1}'`
SEGMENT_HOSTS=`cat $GPHOME/etc/slaves`
OPTIONS='-c gp_maintenance_conn=true'

# check whether all segments replaced with new binary
result=`gpssh -f $GPHOME/etc/slaves "source $GPHOME/greenplum_path.sh;hawq --version;"`
check_error "check version on all hosts"

# result returned by gpssh have special character ^M
count=`echo $result | sed 's/
expected_count=`echo $SEGMENT_HOSTS|wc -w`

if [[ $count -ne $expected_count ]] ; then
    echo "Not all segments replaced with new binary. segment num is $expected_count, there are $count segment be replaced."
    exit 1
fi
echo "All segments have new version binary."

if [ ! -d $HOME/hawqAdminLogs/upgrade ]; then
    mkdir $HOME/hawqAdminLogs/upgrade
    check_error "create dir $HOME/hawqAdminLogs/upgrade"
  # Control will enter here if $DIRECTORY doesn't exist.
fi

hawq config -c upgrade_mode -v on --skipvalidation
check_error "set cluster to upgrade mode"

hawq config -c allow_system_table_mods -v all --skipvalidation
check_error "set allow_system_table_mods to all"

hawq start cluster -a
check_error "start cluster in upgrade mode"

echo "Start hawq cluster in upgrade mode successfully."

# 删除master节点hcatalog数据库
PGOPTIONS="$OPTIONS" psql -t -p $MASTER_PORT -d template1 -c "delete from pg_database where datname='hcatalog';"
check_error " delete hcatalog database in master"
echo "Delete hacatalog database in master successfully."

# 删除segment节点hcatalog数据库
gpssh -f $GPHOME/etc/slaves "source $GPHOME/greenplum_path.sh;PGOPTIONS='$OPTIONS' psql -p $SEGMENT_PORT -d template1 -c \"delete from pg_database where datname='hcatalog';\""
check_error "delete hcatalog database in segment"
echo "Delete hacatalog database in segment successfully."

# 获取所有的用户数据库名称
dbnames=`PGOPTIONS="$OPTIONS" psql -t -p $MASTER_PORT -d template1 -c "select datname from pg_database where datname not in ('template0') order by datname;"`
check_error "get database names in upgrade mode"
echo "Get all database name successfully."

install_function_by_database(){
    # master节点函数注册
    result=`PGOPTIONS="$OPTIONS" psql -a -p $MASTER_PORT -d $1 -f $GPHOME/share/postgresql/${2}.sql 2>&1 > $HOME/hawqAdminLogs/upgrade/${1}_${2}_master.out`
    check_error "install $2 in database $1 in master"

    error_count=`grep -E '(ERROR|FATAL|PANIC)' $HOME/hawqAdminLogs/upgrade/${1}_${2}_master.out|wc -l`
    check_error "install $2 in database $1 in master" $error_count
    echo "Install $2 in database $1 in master successfully."

    if [[ $1 == "template1" ]];then
        #segment节点函数注册
        gpssh -f $GPHOME/etc/slaves "source $GPHOME/greenplum_path.sh;PGOPTIONS='$OPTIONS' psql -a -p $SEGMENT_PORT -d $1 -f $GPHOME/share/postgresql/${2}.sql 2>&1" > $HOME/hawqAdminLogs/upgrade/${1}_${2}.out
        check_error "install $2 in database $1 in segment"
        
        error_count=`grep -E '(ERROR|FATAL|PANIC)' $HOME/hawqAdminLogs/upgrade/${1}_${2}.out|wc -l`
        check_error "install $2 in database $1 in segment" $error_count
        echo "Install $2 in database $1 in segment successfully."
    fi
}

upgrade_catalog() {
    # template1库更改元数据
    if $2 ; then
        # 1、增加hive权限认证列
        # master
        PGOPTIONS="$OPTIONS" psql -p $MASTER_PORT -d $1 -c "alter table pg_authid add column rolcreaterexthive bool;alter table pg_authid add column rolcreatewexthive bool;"
        check_error "add column for hive auth in pg_authid in database $1 in master"
        echo "add column for hive auth in pg_authid in database $1 in master successfully."

        # segment
        if [[ $1 == "template1" ]];then
            # segment
            gpssh -f $GPHOME/etc/slaves "source $GPHOME/greenplum_path.sh;PGOPTIONS='$OPTIONS' psql -p $SEGMENT_PORT -d $1 -c \"alter table pg_authid add column rolcreaterexthive bool;alter table pg_authid add column rolcreatewexthive bool;\""
            check_error "add column for hive auth in pg_authid in database $1 in segment"
            echo "Add column for hive auth in pg_authid in database $1 in segment successfully."
        fi

        # 2、hive 安装
        install_function_by_database $1 "hive_install"
    
        # json defered because oid issue
        # 3、json相关元数据改动
        #hawq ssh -f hostfile -e 'PGOPTIONS=\'-c gp_maintenance_conn=true\' psql -a -p $hawq_master_address_port -d template1 -f $GPHOME/share/postgresql/json_install.sql 2>&1 /tmp/json_install.out'
        #grep ERROR /tmp/josn_install.out | wc -l
        #if [[ num -ne 0 ]]
        #echo 'Failed to register json function'
        #fi
    
        # 4、orc安装
        install_function_by_database $1 "orc_install"
    
        # 5、欧式距离安装
        install_function_by_database $1 "array_distance_install"
    fi
    
    # 6、增加magma权限认证
    PGOPTIONS="$OPTIONS" psql -t -p $MASTER_PORT -d $1 -c "alter table pg_authid add column rolcreaterextmagma bool;alter table pg_authid add column rolcreatewextmagma bool;"
    check_error "add magma role column in pg_authid in database $1 in master"
    echo "Add magma role column in pg_authid in database $1 in master successfully."
    
    if [[ $1 == "template1" ]];then
        #segment节点添加magma权限
        gpssh -f $GPHOME/etc/slaves "source $GPHOME/greenplum_path.sh;PGOPTIONS='$OPTIONS' psql -p $SEGMENT_PORT -d $1 -c \"alter table pg_authid add column rolcreaterextmagma bool;alter table pg_authid add column rolcreatewextmagma bool;\""
        check_error "add magma role column in pg_authid in database $1 in segment"
        echo "Add magma role column in pg_authid in database $1 in segment successfully."
    fi
    
    # 7、magma函数注册
    install_function_by_database $1 "magma_install"
    
    # 8、监控函数注册
    install_function_by_database $1 "monitor_install"
}

#升级所有的数据库
for dbname in $dbnames
do
    echo "upgrade $dbname"
    upgrade_catalog $dbname $upgrade_total
done

#停止集群
hawq config -c upgrade_mode -v off --skipvalidation
check_error "set cluster to normal mode"

hawq config -c allow_system_table_mods -v none --skipvalidation
check_error "set allow_system_table_mods to none"
echo "Set cluster to normal mode successfully."

hawq stop cluster -a
check_error "stop cluster"
echo "Upgrade to version $target_version sucessfully. cluster can be started now!"