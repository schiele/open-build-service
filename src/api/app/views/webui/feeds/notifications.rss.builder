xml.rss version: '2.0' do
  xml.channel do
    xml.title "#{@user.realname}'s (#{@user.login}) notifications"
    xml.description "Event's notifications from #{@configuration['title']}"
    xml.link url_for only_path: false, controller: 'main', action: 'index'
    xml.language "en"
    xml.pubDate Time.now
    xml.generator @configuration['title']

    @notifications.each do |notification|
      xml.item do
        xml.title notification.event_type
        xml.description notification.event_payload
        xml.category "#{notification.event_type}/#{notification.subscription_receiver_role}"
        xml.pubDate notification.created_at
        xml.author "#{@configuration['title']}"
        xml.link url_for only_path: false, controller: 'main', action: 'index'
      end
    end
  end
end
