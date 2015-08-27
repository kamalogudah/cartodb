# encoding: UTF-8

# See http://www.rubydoc.info/gems/net-ldap/0.11
require 'net/ldap'

class Carto::Ldap::Configuration < ActiveRecord::Base

  # Not encrypted
  ENCRYPTION_NONE = nil
  # Encrypted from start
  ENCRYPTION_SIMPLE_TLS = 'simple_tls'
  # Upgrade to encrypted once connected
  ENCRYPTION_START_TLS = 'start_tls'

  ENCRYPTION_SSL_VERSION_DEFAULT = nil
  ENCRYPTION_SSL_VERSION_TLSV1_1 = 'TLSv1_1'

  self.table_name = 'ldap_configurations'

  belongs_to :organization, class_name: Carto::Organization

  # @param Uuid id  (Self-generated)
  # @param Uuid organization_id
  # @param String host LDAP host or ip address
  # @param Int port LDAP port e.g. 389, 636 (LDAPS)
  # @param String encryption (Optional) Encryption type to use. Empty means standard/simple Auth
  # @param String ca_file Certificate file path for start_tls encryption. Example: "/etc/cafile.pem"
  # @param String ssl_version For start_tls_encryption. Example: "TLSv1_1"
  # @param String connection_user Full CN for "search connections" to LDAP: `CN=admin, DC=cartodb, DC=COM`
  # @param String connection_password Password for "search connections" to LDAP
  # @param String user_id_field Which LDAP entry field represents the user id. e.g. `sAMAccountName`, `uid`
  # @param String username_field Which LDAP entry field represents the username (Optional)
  # @param String username_field Which LDAP entry field represents the email
  # @param String domain_bases List of DCs conforming the path (serialized)
  # @param String user_object_class Name of the attribute where the sers are maped in LDAP
  # @param String group_object_class Name of the attribute where the groups are maped in LDAP
  # @param DateTime created_at (Self-generated)
  # @param DateTime updated_at (Self-generated)

  validates :organization, :host, :port, :connection_user, :connection_password, :user_id_field, :email_field, 
              :user_object_class, :group_object_class, :presence => true
  validates :ca_file, :username_field, :length => { :minimum => 0, :allow_nil => true }
  # TODO: new validation 
  #validates :domain_bases, :length => { :minimum => 1, :allow_nil => false }
  validates :encryption, :inclusion => { :in => [ ENCRYPTION_SIMPLE_TLS, ENCRYPTION_START_TLS ], :allow_nil => true }
  validates :ssl_version, :inclusion => { :in => [ ENCRYPTION_SSL_VERSION_TLSV1_1 ], :allow_nil => true }

  def domain_bases_list
    self.domain_bases.split(',')
  end

  def domain_bases_list=(list)
    self.domain_bases = list.join(',')
  end

  # Returns matching Carto::Ldap::Entry or false if credentials are wrong
  # @param String username. No full CN, just the username, e.g. 'administrator1'
  # @param String password
  def authenticate(username, password)
    # To be used for domain bases search
    username_stringified_filter = "cn=#{username}"
    # To be used in real search
    username_filter =  Net::LDAP::Filter.eq('cn', username)

    domain_base = domain_bases_list.find { |domain|
      # This is just checking if provided auth user can connect, connection is not stored
      connect("#{username_stringified_filter},#{domain}", password).bind
    }
    return false if domain_base.nil?

    search_results = search(domain_base, username_filter)
    return false if search_results.nil?

    #Sample result
    # [ #<Net::LDAP::Entry:0x00000008c54628 @myhash={
    #     :dn=>["cn=test,dc=cartodb"], 
    #     :objectclass=>["simpleSecurityObject", "organizationalRole"], 
    #     :cn=>["test"], 
    #     :description=>["xxxx"], 
    #     :userpassword=>["{SSHA}aaaaa"] 
    # }> ]
    Carto::Ldap::Entry.new(search_results.is_a?(Array) ? search_results.first : search_results, self)
  end

  # INFO: Resets connection if already made
  def test_connection
    @conn = nil
    connection.bind
  end

  def users(objectClass = self.user_object_class)
    search_in_domain_bases(Net::LDAP::Filter.eq('objectClass', objectClass))
  end

  def groups(objectClass = self.group_object_class)
    search_in_domain_bases(Net::LDAP::Filter.eq('objectClass', objectClass))
  end

  private

  def search_in_domain_bases(filter)
    domain_bases_list.map { |domain|
      search(domain, filter)
    }.flatten.compact
  end

  # @param String base DC to search at
  # @Param Net::LDAP::Filter filter (Optional)
  def search(base, filter = nil)
    if filter
      connection.search(base: base, filter: filter)
    else
      connection.search(base: base)
    end
  end

  # Performs connection always with the search connection user
  def connection
    @conn ||= connect
  end

  # Connect, by default with the search connection user
  # @param String user full CN, like `CN=test_user, CN=developers, DC=cartodb, DC=COM`
  # @param String password Connection password
  # @throws InvalidConfigurationEncryptionError
  def connect(user = self.connection_user, password = self.connection_password)
    ldap = Net::LDAP.new
    ldap.host = self.host
    ldap.port = self.port
    configure_encryption(ldap)
    # implicity this does basic/simple auth if no encryption added above
    ldap.auth(user, password)
    ldap
  end

  def configure_encryption(ldap)
    tls_options = OpenSSL::SSL::SSLContext::DEFAULT_PARAMS

    case self.encryption
    when ENCRYPTION_NONE
      return
    when ENCRYPTION_START_TLS
      tls_options.merge!(:ca_file => self.ca_file) if self.ca_file
    when ENCRYPTION_SIMPLE_TLS
      # No special value needed
    else
      raise InvalidConfigurationEncryptionError.new(self.encryption)
    end

    tls_options.merge!(:verify_mode => OpenSSL::SSL::VERIFY_NONE)
    
    # Default value is "SSLv23" at the gem
    tls_options.merge!(:ssl_version => self.ssl_version) if self.ssl_version

    ldap.encryption(method: self.encryption.to_sym, tls_options: tls_options)
  end

end

class InvalidConfigurationEncryptionError < StandardError
  def initialize(incorrect_encryption_value)
    super("Invalid encryption value supplied: #{incorrect_encryption_value}. Valid values: [nil, '', '']")
  end
end