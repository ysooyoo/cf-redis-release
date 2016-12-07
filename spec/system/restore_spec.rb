require 'system_spec_helper'
require 'httparty'

RESTORE_BINARY = '/var/vcap/jobs/redis-backups/bin/restore'
BACKUP_PATH = '/var/vcap/store/redis-backup/dump.rdb'

shared_examples 'it can restore Redis' do |plan|
  before(:all) do
    @service_instance, @service_binding = provision_and_bind plan

    @vm_ip = @service_binding.credentials[:host]
    @preprovision_timestamp = root_execute_on(@vm_ip, "date +%s")
    @client = service_client_builder(@service_binding)

    stage_dump_file @vm_ip
    expect(@client.read("moaning")).to_not eq("myrtle")

    restore_args = get_restore_args plan, @service_instance.id
    root_execute_on(@vm_ip, "#{RESTORE_BINARY} #{restore_args}")
  end

  after(:all) do
    expect(broker_registered?).to be true

    service_broker.unbind_instance(@service_binding)
    service_broker.deprovision_instance(@service_instance)
  end

  it 'restores data to the instance' do
    expect(@client.read("moaning")).to eq("myrtle")
  end

  it 'logs successful completion of restore' do
    vm_log = root_execute_on(@vm_ip, "cat /var/vcap/sys/log/redis-backups/redis-backups.log")
    contains_expected_log = drop_log_lines_before(@preprovision_timestamp, vm_log).any? do |line|
      line.include?('"restore.LogRestoreComplete","log_level":1,"data":{"message":"Redis data restore completed successfully"}}')
    end
  end
end

describe 'restore' do
  context 'shared-vm' do
    it_behaves_like 'it can restore Redis', 'shared-vm'
  end

  context 'dedicated-vm' do
    it_behaves_like 'it can restore Redis', 'dedicated-vm'
  end
end

def broker_registered?
  uri = URI.parse('https://' + bosh_manifest.property('broker.host') + '/v2/catalog')

  auth = {
    username: bosh_manifest.property("broker.username"),
    password: bosh_manifest.property("broker.password")
  }

  15.times do |n|
    puts "Checking if broker is responding, Attempt: #{n}"
    response = HTTParty.get(uri, verify: false, basic_auth: auth)

    if response.code == 200
      return true
    end

    sleep 1
  end

  false
end

def stage_dump_file vm_ip
  local_dump = 'spec/fixtures/moaning-dump.rdb'
  ssh_gateway.scp_to(vm_ip, local_dump, '/tmp/moaning-dump.rdb')
  root_execute_on(vm_ip, "mv /tmp/moaning-dump.rdb #{BACKUP_PATH}")
end

def get_restore_args plan, instance_id
  restore_args = "--sourceRDB #{BACKUP_PATH}"

  if plan == 'shared-vm' then
    restore_args = "#{restore_args} --sharedVmGuid #{instance_id}"
  end
end

def provision_and_bind plan
  service_name = bosh_manifest.property('redis.broker.service_name')
  service_instance = service_broker.provision_instance(service_name, plan)
  service_binding  = service_broker.bind_instance(service_instance)
  return service_instance, service_binding
end
