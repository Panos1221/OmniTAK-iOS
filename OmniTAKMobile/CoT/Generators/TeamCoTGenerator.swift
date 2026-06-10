//
//  TeamCoTGenerator.swift
//  OmniTAKMobile
//
//  Generate CoT messages for team coordination
//

import Foundation
import CoreLocation

class TeamCoTGenerator {

    static func generateTeamMembershipCoT(team: Team, member: TeamMember, callsign: String) -> String {
        let uid = "TEAM-\(team.id)-\(member.uid)"

        let lat = member.clCoordinate?.latitude ?? 0.0
        let lon = member.clCoordinate?.longitude ?? 0.0

        let detail = """
                <contact callsign="\(callsign.xmlEscaped)"/>
                <__group name="\(team.name.xmlEscaped)" role="\(member.role.rawValue)"/>
                <__team id="\(team.id)" name="\(team.name.xmlEscaped)" color="\(team.color.hexColor)"/>
                <__member uid="\(member.uid)" callsign="\(member.callsign.xmlEscaped)" role="\(member.role.shortName)" online="\(member.isOnline)"/>
                <status readiness="true"/>
        """

        return CoTXMLBuilder.buildEvent(
            uid: uid,
            type: "a-f-G-U-C",
            how: "h-g-i-g-o",
            staleAfter: 3600, // 1 hour stale
            lat: lat,
            lon: lon,
            detail: detail
        )
    }

    static func generateTeamBroadcastCoT(broadcast: TeamBroadcast, team: Team, callsign: String) -> String {
        let now = Date()

        let uid = "TEAM-BROADCAST-\(broadcast.id)"

        let lat = broadcast.coordinate?.clCoordinate.latitude ?? 0.0
        let lon = broadcast.coordinate?.clCoordinate.longitude ?? 0.0

        let typeCode = broadcast.isAlert ? "b-a-o-tbl" : "b-t-f"
        let startStr = CoTXMLBuilder.timestamp(broadcast.timestamp)

        let detail = """
                <contact callsign="\(callsign.xmlEscaped)"/>
                <remarks source="\(broadcast.senderId)" time="\(startStr)">\(broadcast.message.xmlEscaped)</remarks>
                <__team id="\(team.id)" name="\(team.name.xmlEscaped)"/>
                <__broadcast id="\(broadcast.id)" sender="\(broadcast.senderId)" senderCallsign="\(broadcast.senderCallsign.xmlEscaped)" alert="\(broadcast.isAlert)"/>
        """

        return CoTXMLBuilder.buildEvent(
            uid: uid,
            type: typeCode,
            how: "h-g-i-g-o",
            time: now,
            start: broadcast.timestamp,
            staleAfter: 3600, // 1 hour stale
            lat: lat,
            lon: lon,
            detail: detail
        )
    }

    static func generateTeamInviteCoT(invite: TeamInvite) -> String {
        let uid = "TEAM-INVITE-\(invite.id)"

        let detail = """
                <contact callsign="\(invite.inviterCallsign.xmlEscaped)"/>
                <remarks>Team Invite: Join \(invite.teamName.xmlEscaped)</remarks>
                <__team_invite id="\(invite.id)" teamId="\(invite.teamId)" teamName="\(invite.teamName.xmlEscaped)" teamColor="\(invite.teamColor.hexColor)" inviterId="\(invite.inviterId)" inviterCallsign="\(invite.inviterCallsign.xmlEscaped)" inviteeId="\(invite.inviteeId)" inviteeCallsign="\(invite.inviteeCallsign.xmlEscaped)" status="\(invite.status.rawValue)"/>
        """

        return CoTXMLBuilder.buildEvent(
            uid: uid,
            type: "b-t-f",
            how: "h-g-i-g-o",
            staleAfter: 86400, // 24 hour stale
            lat: 0.0,
            lon: 0.0,
            detail: detail
        )
    }
}
