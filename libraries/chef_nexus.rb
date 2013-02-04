#
# Cookbook Name:: nexus
# Library:: chef_nexus
#
# Author:: Kyle Allan (<kallan@riotgames.com>)
# Copyright 2012, Riot Games
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#
class Chef
  module Nexus
    DATABAG = "nexus"
    WILDCARD_DATABAG_ITEM = "_wildcard"
    CERTIFICATES_DATABAG_ITEM = "certificates"
    SSL_CERTIFICATE_DATABAG_ITEM = "ssl_certificate"
    SSL_CERTIFICATE_CRT = "crt"
    SSL_CERTIFICATE_KEY = "key"
    
    class << self

      # Loads the nexus encrypted data bag item. Attempts to load a data bag item
      # named after the current Chef environment. If one is not found, an item named
      # "_wildcard" will be used.
      # 
      # @return [Chef::Mash] the data bag item as a Mash with indifferent access
      def get_nexus_data_bag(node)
        encrypted_data_bag_for(node, DATABAG)
      end

      # Loads the proxy_repositories entry from the nexus data bag item.
      # 
      # @param  node [Chef::Node] the Chef node
      # 
      # @return [Chef::Mash] the proxy_repositories entry in the data bag item
      def get_proxy_repositories(node)
        get_nexus_data_bag(node)[:proxy_repositories]
      end

      # Loads the hosted_repositories entry from the nexus data bag item.
      # 
      # @param  node [Chef::Node] the Chef node
      # 
      # @return [Chef::Mash] the hosted_repositories entry in the data bag item
      def get_hosted_repositories(node)
        get_nexus_data_bag(node)[:hosted_repositories]
      end

      # Loads the group_repositories entry from the nexus data bag item.
      # 
      # @param  node [Chef::Node] the Chef node
      # 
      # @return [Chef::Mash] the group_repositories entry in the data bag item
      def get_group_repositories(node)
        get_nexus_data_bag(node)[:group_repositories]
      end

      # Loads the ssl_certificate encrypted data bag item.
      # 
      # @example
      #   knife data bag load nexus proxy_repositories --secret-file
      # 
      # @param  node [Chef::Node] the Chef node
      # 
      # @return [Chef::EncryptedDataBagItem] the loaded data bag item
      def get_ssl_certificate_data_bag
        begin
          data_bag_item = Chef::EncryptedDataBagItem.load(DATABAG, SSL_CERTIFICATE_DATABAG_ITEM)
        rescue Net::HTTPServerException => e
          raise Nexus::EncryptedDataBagNotFound.new(CREDENTIALS_DATABAG_ITEM)
        end
        data_bag_item
      end

      # Loads and decode64s the SSL_CERTIFICATE_CRT entry from the given
      # data bag item.
      # 
      # @param  data_bag_item [Chef::DataBagItem] the data bag item
      # 
      # @return [String] the decoded certificate string
      def get_ssl_certificate_crt(data_bag_item)
        require 'base64'
        Base64.decode64(data_bag_item[SSL_CERTIFICATE_CRT])
      end

      # Loads and decode64s the SSL_CERTIFICATE_KEY entry from the given
      # data bag item. 
      #
      # @param  data_bag_item [Chef::DataBagItem] the data bag item
      # 
      # @return [String] the decoded certificate key string
      def get_ssl_certificate_key(data_bag_item)
        require 'base64'
        Base64.decode64(data_bag_item[SSL_CERTIFICATE_KEY])
      end

      # Loads the certificates data bag item.
      # 
      # @example
      #   knife data bag load nexus certificates --secret-file
      # 
      # @return [Chef::EncryptedDataBagItem] the loaded data bag item
      def get_certificates_data_bag(node)
        begin
          data_bag_item = Chef::EncryptedDataBagItem.load(DATABAG, CERTIFICATES_DATABAG_ITEM)
        rescue Net::HTTPServerException => e
          raise Nexus::EncryptedDataBagNotFound.new(CERTIFICATES_DATABAG_ITEM)
        end
        validate_certificates_data_bag(data_bag_item, node)
        data_bag_item
      end

      # Creates and returns an instance of a NexusCli::RemoteFactory that
      # will be authenticated with the info inside the credentials data bag
      # item.
      # 
      # @param  node [Chef::Node] the node
      # 
      # @return [NexusCli::RemoteFactory] a connection to a Nexus server
      def nexus(node)
        require 'nexus_cli'
        data_bag_item = get_credentials_data_bag        
        default_credentials = data_bag_item["default_admin"]
        updated_credentials = data_bag_item["updated_admin"]

        overrides = {"url" => node[:nexus][:cli][:url], "repository" => node[:nexus][:cli][:repository]}
        if Chef::Config[:solo]
          begin
            merged_credentials = overrides.merge(default_credentials)
            NexusCli::RemoteFactory.create(merged_credentials, node[:nexus][:ssl][:verify])
          rescue NexusCli::PermissionsException, NexusCli::CouldNotConnectToNexusException, NexusCli::UnexpectedStatusCodeException => e
            merged_credentials = overrides.merge(updated_credentials)
            NexusCli::RemoteFactory.create(merged_credentials, node[:nexus][:ssl][:verify])
          end
        else
          if node[:nexus][:cli][:default_admin_credentials_updated]
            credentials = data_bag_item["updated_admin"]
          else
            credentials = data_bag_item["default_admin"]
          end
          merged_credentials = overrides.merge(credentials)
          NexusCli::RemoteFactory.create(merged_credentials, node[:nexus][:ssl][:verify])
        end
      end

      # Checks to ensure the Nexus server is available. When
      # it is unavailable, the Chef run is failed. Otherwise
      # the Chef run continues.
      # 
      # @param  node [Chef::Node] the Chef node
      # 
      # @return [NilClass]
      def ensure_nexus_available(node)
        Chef::Application.fatal!("Could not connect to Nexus. Please ensure Nexus is running.") unless Chef::Nexus.nexus_available?(node)
      end

      # Attempts to connect to the Nexus and retries if a connection 
      # cannot be made.
      # 
      # @param  node [Chef::Node] the node
      # 
      # @return [Boolean] true if a connection could be made, false otherwise
      def nexus_available?(node)        
        retries = node[:nexus][:cli][:retries]
        begin
          nexus(node)
          return true
        rescue NexusCli::CouldNotConnectToNexusException, NexusCli::UnexpectedStatusCodeException => e
          if retries > 0
            retries -= 1
            Chef::Log.info "Could not connect to Nexus, #{retries} attempt(s) left"
            sleep node[:nexus][:cli][:retry_delay]
            retry
          end
          return false
        end
      end

      # Checks the Nexus users credentials and returns false if they
      # have been changed.
      # 
      # @param  username [String] the Nexus username
      # @param  password [String] the Nexus password
      # @param  node [Chef::Node] the Chef node
      # 
      # @return [Boolean] true if a connection can be made, false otherwise
      def check_old_credentials(username, password, node)
        require 'nexus_cli'
        overrides = {"url" => node[:nexus][:cli][:url], "repository" => node[:nexus][:cli][:repository], "username" => username, "password" => password}
        begin
          nexus = NexusCli::RemoteFactory.create(overrides, node[:nexus][:ssl][:verify])
          true
        rescue NexusCli::PermissionsException, NexusCli::CouldNotConnectToNexusException, NexusCli::UnexpectedStatusCodeException => e
          false
        end
      end

      # Returns a 'safe-for-Nexus' identifier by replacing
      # spaces with underscores and downcasing the entire
      # String.
      # 
      # @param  nexus_identifier [String] a Nexus identifier
      # 
      # @example
      #   Chef::Nexus.parse_identifier("Artifacts Repository") => "artifacts_repository"
      # 
      # @return [String] a safe-for-Nexus version of the identifier
      def parse_identifier(nexus_identifier)
        nexus_identifier.gsub(" ", "_").downcase
      end

      def decode(value)
        require 'base64'
        Base64.decode64(value)
      end

      private

        def encrypted_data_bag_for(node, data_bag)
          environment_data_bag_item = encrypted_data_bag_item(data_bag, node.chef_environment)
          
          if environment_data_bag_item
            return environment_data_bag_item
          end

          default_data_bag_item = encrypted_data_bag_item(data_bag, "_wildcard")
          if default_data_bag_item
            msg = "Encrypted data bag '#{data_bag}' not found for environment '#{node.chef_environment}'! "
            msg << "Using default data bag item '_wildcard'."
            msg = "[#{cookbook}] #{msg}" if cookbook
            Chef::Log.warn msg
            return default_data_bag_item
          end

          raise Nexus::EncryptedDataBagNotFound.new(data_bag)
        end

        def encrypted_data_bag_item(data_bag, data_bag_item)
          Mash.from_hash(Chef::EncryptedDataBagItem.load(data_bag, data_bag_item).to_hash)
        rescue Net::HTTPServerException => e
          nil
        end

        # Finds a data bag item. Looks first for an entry in the data bag item
        # for the node's hostname. Otherwise returns the _wildcard entry.
        # 
        # @param [Node] The node hash
        # @param [String] The data bag to load
        # @param [String] The data bag item to load
        # 
        # @return [DataBagItem] The data bag item found
        def data_bag_item_for_hostname(node, data_bag, data_bag_item)
          data_bag_item = Chef::DataBagItem.load(data_bag, data_bag_item)
          if data_bag_item[node[:hostname]]
            return data_bag_item[node[:hostname]]
          end

          default_data_bag_item = data_bag_item['_wildcard']
          if default_data_bag_item
            message = "Data bag item #{data_bag_item} does not contain an entry for '#{node[:hostname]}'. "
            message << "Attempting to use default data bag item entry '_wildcard'."
            Chef::Log.warn message
            return default_data_bag_item
          end

          raise Nexus::EncryptedDataBagNotFound.new(data_bag_item)
        end
    end
  end
end