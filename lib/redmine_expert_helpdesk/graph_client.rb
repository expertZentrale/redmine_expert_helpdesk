# Microsoft-Graph-Client fuer den Helpdesk-Mailabruf und -Versand.
#
# Verwendet den OAuth2 Client-Credentials-Flow (App-Only) gegen Azure AD / Entra ID.
# Die Zugangsdaten (Tenant-ID, Client-ID, Client-Secret) werden zentral in den
# Plugin-Einstellungen gepflegt. Das Access-Token wird im Rails-Cache
# zwischengespeichert (Redis in Produktion).
#
# Benoetigte Application-Permissions der App-Registrierung:
#   - Mail.ReadWrite (Mails lesen und in Unterordner verschieben)
#   - Mail.Send      (Antworten und Autoresponder versenden)
# Der Zugriff sollte per ApplicationAccessPolicy auf die Helpdesk-Postfaecher
# eingeschraenkt werden (siehe README).

require 'net/http'
require 'uri'
require 'json'
require 'base64'
require 'digest'

module RedmineExpertHelpdesk
  class GraphClient
    GRAPH_BASE  = 'https://graph.microsoft.com/v1.0'.freeze
    TOKEN_CACHE_PREFIX = 'redmine_expert_helpdesk/graph_token'.freeze

    # Seconds. A JSON call (list, folder lookup, move, mark read, token) answers
    # within a second or two when Graph is healthy; when it is not, Graph itself
    # gives up after about 30 s with a 504. 20 s ends that wait sooner, and every
    # second counts while a fetch holds a web thread (see FetchAll). Raw MIME and
    # sending carry attachments and keep the long timeout.
    OPEN_TIMEOUT     = 10
    READ_TIMEOUT     = 20
    TRANSFER_TIMEOUT = 60

    # GraphError inherits from ProviderError so callers can rescue the common
    # provider error and still catch Graph failures.
    class GraphError < MailProvider::ProviderError; end

    class ConfigurationError < GraphError; end

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_expert_helpdesk
    end

    def configured?
      %w[tenant_id client_id client_secret].all? { |k| @settings[k].present? }
    end

    # Liefert die Nachrichten eines Ordners (aelteste zuerst), maximal +top+ Stueck.
    # +folder+ ist der Anzeigename des Ordners (z. B. "Inbox" oder "Posteingang").
    def list_messages(mailbox, folder, top = 25)
      folder_id = resolve_folder_id(mailbox, folder)
      query = URI.encode_www_form(
        '$top'     => top.to_i,
        '$filter'  => 'isRead eq false',
        '$orderby' => 'receivedDateTime asc',
        '$select'  => 'id,subject,from,receivedDateTime,internetMessageId'
      )
      response = get("/users/#{escape(mailbox)}/mailFolders/#{folder_id}/messages?#{query}")
      response['value'] || []
    end

    # Laedt die komplette Nachricht als MIME (RFC 2822) – Eingabe fuer den Redmine MailHandler.
    def message_mime(mailbox, message_id)
      get_raw("/users/#{escape(mailbox)}/messages/#{message_id}/$value")
    end

    # Verschiebt eine Nachricht in einen anderen Ordner (z. B. "Verarbeitet").
    def move_message(mailbox, message_id, destination_folder)
      folder_id = resolve_folder_id(mailbox, destination_folder)
      post("/users/#{escape(mailbox)}/messages/#{message_id}/move",
           { 'destinationId' => folder_id })
    end

    # Markiert eine Nachricht als gelesen.
    def mark_as_read(mailbox, message_id)
      patch("/users/#{escape(mailbox)}/messages/#{message_id}", { 'isRead' => true })
    end

    # Listet alle Ordnernamen des Postfachs (Top-Level + direkte Unterordner von Inbox).
    # Liefert ein sortiertes Array von Anzeigenamen.
    def list_folders(mailbox)
      query = URI.encode_www_form('$select' => 'id,displayName', '$top' => 100)
      top_level = (get("/users/#{escape(mailbox)}/mailFolders?#{query}")['value'] || [])
                  .map { |f| f['displayName'] }

      inbox_children = begin
        (get("/users/#{escape(mailbox)}/mailFolders/inbox/childFolders?#{query}")['value'] || [])
          .map { |f| "Inbox/#{f['displayName']}" }
      rescue GraphError
        []
      end

      (top_level + inbox_children).uniq.sort
    end

    # Erstellt einen neuen Top-Level-Ordner im Postfach.
    def create_folder(mailbox, folder_name)
      post("/users/#{escape(mailbox)}/mailFolders", { 'displayName' => folder_name })
    end

    # Sucht einen Ordner und legt ihn an, falls er noch nicht existiert.
    # Gibt die Ordner-ID zurueck.
    def find_or_create_folder(mailbox, folder_name)
      return nil if folder_name.blank?
      resolve_folder_id(mailbox, folder_name)
    rescue GraphError
      result = create_folder(mailbox, folder_name)
      # Cache leeren, damit resolve_folder_id beim naechsten Aufruf den echten Eintrag laedt
      cache_key = "redmine_expert_helpdesk/folder/#{mailbox}/#{folder_name}"
      Rails.cache.delete(cache_key)
      result['id']
    end

    # Versendet eine Mail im Namen des Postfachs (landet in "Gesendete Elemente").
    # +message+ entspricht der Graph-Message-Struktur (subject, body, toRecipients, ...).
    def send_mail(mailbox, message, save_to_sent_items = true)
      post("/users/#{escape(mailbox)}/sendMail",
           { 'message' => message, 'saveToSentItems' => save_to_sent_items })
    end

    # Versendet eine Mail als rohe RFC-2822-MIME-Nachricht ueber den Graph-MIME-Endpunkt.
    # Dabei wird Content-Type: text/plain + Base64-kodierter MIME-Body verwendet.
    # Dieser Weg ist zuverlaessiger fuer Inline-Bilder (CID), weil Exchange das HTML
    # bei JSON-Requests umschreibt und dabei cid:-Referenzen entkoppeln kann.
    def send_mail_mime(mailbox, mime_string)
      encoded = Base64.strict_encode64(mime_string)
      uri  = URI("#{GRAPH_BASE}/users/#{escape(mailbox)}/sendMail")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = TRANSFER_TIMEOUT
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{access_token}"
      req['Content-Type']  = 'text/plain'
      req.body = encoded
      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise GraphError.new(I18n.t(:error_helpdesk_graph_send_failed, :code => response.code,
                                    :detail => graph_error_detail(response.body)),
                             response.code.to_i, response.body)
      end
      response
    end

    # Ermittelt die Ordner-ID anhand des Anzeigenamens. Bekannte Standardordner
    # ("inbox" etc.) werden direkt als Well-Known-Name verwendet.
    def resolve_folder_id(mailbox, folder)
      return 'inbox' if folder.blank? || folder.casecmp('inbox').zero? || folder.casecmp('posteingang').zero?

      cache_key = "redmine_expert_helpdesk/folder/#{mailbox}/#{folder}"
      cached = Rails.cache.read(cache_key)
      return cached if cached

      query = URI.encode_www_form(
        '$filter' => "displayName eq '#{folder.gsub("'", "''")}'",
        '$select' => 'id,displayName'
      )
      response = get("/users/#{escape(mailbox)}/mailFolders?#{query}")
      entry = (response['value'] || []).first
      raise GraphError.new(I18n.t(:error_helpdesk_graph_folder_not_found, :folder => folder, :mailbox => mailbox)) unless entry

      Rails.cache.write(cache_key, entry['id'], :expires_in => 12.hours)
      entry['id']
    end

    # --- Token-Handling -----------------------------------------------------

    def access_token
      cache_key = token_cache_key
      cached = Rails.cache.read(cache_key)
      return cached if cached

      raise ConfigurationError.new(I18n.t(:error_helpdesk_graph_not_configured)) unless configured?

      uri = URI("https://login.microsoftonline.com/#{@settings['tenant_id']}/oauth2/v2.0/token")
      response = post_token_form(uri,
                                 'client_id'     => @settings['client_id'],
                                 'client_secret' => @settings['client_secret'],
                                 'scope'         => 'https://graph.microsoft.com/.default',
                                 'grant_type'    => 'client_credentials')

      body = JSON.parse(response.body) rescue {}
      unless response.is_a?(Net::HTTPSuccess) && body['access_token']
        raise GraphError.new(I18n.t(:error_helpdesk_graph_token_failed, :error => body['error_description'] || response.code),
                             response.code.to_i, response.body)
      end

      # Token etwas frueher verfallen lassen als von Azure angegeben
      ttl = [body['expires_in'].to_i - 120, 60].max
      Rails.cache.write(cache_key, body['access_token'], :expires_in => ttl.seconds)
      body['access_token']
    end

    # The cache key includes a fingerprint of the credentials, so rotating the
    # client secret takes effect immediately instead of after the cached token
    # expires.
    def token_cache_key
      fingerprint = Digest::SHA256.hexdigest(
        [@settings['tenant_id'], @settings['client_id'], @settings['client_secret']].join('|')
      )[0, 12]
      "#{TOKEN_CACHE_PREFIX}/#{fingerprint}"
    end

    private

    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end

    def get(path)
      JSON.parse(request(:get, path).body)
    end

    def get_raw(path)
      request(:get, path, nil, :read_timeout => TRANSFER_TIMEOUT).body
    end

    def post(path, payload)
      response = request(:post, path, payload)
      response.body.present? ? (JSON.parse(response.body) rescue {}) : {}
    end

    def patch(path, payload)
      response = request(:patch, path, payload)
      response.body.present? ? (JSON.parse(response.body) rescue {}) : {}
    end

    # Net::HTTP.post_form has no timeouts of its own (60 s defaults).
    def post_token_form(uri, params)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Post.new(uri.request_uri)
      req.set_form_data(params)
      http.request(req)
    end

    def request(method, path, payload = nil, read_timeout: READ_TIMEOUT)
      uri = URI("#{GRAPH_BASE}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = read_timeout

      req = case method
            when :get   then Net::HTTP::Get.new(uri)
            when :post  then Net::HTTP::Post.new(uri)
            when :patch then Net::HTTP::Patch.new(uri)
            end
      req['Authorization'] = "Bearer #{access_token}"
      req['Accept'] = 'application/json'
      if payload
        req['Content-Type'] = 'application/json'
        req.body = payload.to_json
      end

      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise GraphError.new(I18n.t(:error_helpdesk_graph_request_failed, :code => response.code,
                                    :request => "#{method.to_s.upcase} #{path}",
                                    :detail => graph_error_detail(response.body)),
                             response.code.to_i, response.body)
      end
      response
    end

    # Graph puts the actual reason in the response body, not in the status code.
    # A 403 is either "ErrorAccessDenied" (the RBAC scope does not cover this
    # mailbox) or "MailboxNotEnabledForRESTAPI" (the mailbox is inactive,
    # soft-deleted or hosted on-premises) - completely different problems that
    # need completely different fixes, and the status alone tells them apart not
    # at all. Without this the operator only ever sees "(403)".
    def graph_error_detail(body)
      error = JSON.parse(body.to_s)['error'] rescue nil
      return '' unless error.is_a?(Hash)

      detail = [error['code'], error['message']].map(&:to_s).reject(&:empty?).join(': ')
      detail.empty? ? '' : " - #{detail}"
    end
  end
end
