/*
 Copyright 2015 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "RecentTableViewCell.h"

#import "AvatarGenerator.h"

#import "MXEvent.h"

#import "RiotDesignValues.h"

#import "MXRoom+Riot.h"

@implementation RecentTableViewCell

#pragma mark - Class methods

- (void)awakeFromNib
{
    [super awakeFromNib];
    
    // Initialize unread count badge
    [_missedNotifAndUnreadBadgeBgView.layer setCornerRadius:10];
    _missedNotifAndUnreadBadgeBgViewWidthConstraint.constant = 0;
    
    self.roomTitle.textColor = kRiotTextColorBlack;
    self.lastEventDescription.textColor = kRiotTextColorGray;
    self.lastEventDate.textColor = kRiotTextColorGray;
    self.missedNotifAndUnreadBadgeLabel.textColor = [UIColor whiteColor];
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    
    // Round image view
    [_roomAvatar.layer setCornerRadius:_roomAvatar.frame.size.width / 2];
    _roomAvatar.clipsToBounds = YES;
}

- (void)render:(MXKCellData *)cellData
{
    // Hide by default missed notifications and unread widgets
    self.missedNotifAndUnreadIndicator.hidden = YES;
    self.missedNotifAndUnreadBadgeBgView.hidden = YES;
    self.missedNotifAndUnreadBadgeBgViewWidthConstraint.constant = 0;
    
    roomCellData = (id<MXKRecentCellDataStoring>)cellData;
    if (roomCellData)
    {
        // Report computed values as is
        self.roomTitle.text = roomCellData.roomDisplayname;
        self.lastEventDate.text = roomCellData.lastEventDate;
        
        // Manage lastEventAttributedTextMessage optional property
        if ([roomCellData respondsToSelector:@selector(lastEventAttributedTextMessage)])
        {
            // Force the default text color for the last message (cancel highlighted message color)
            NSMutableAttributedString *lastEventDescription = [[NSMutableAttributedString alloc] initWithAttributedString:roomCellData.lastEventAttributedTextMessage];
            [lastEventDescription addAttribute:NSForegroundColorAttributeName value:kRiotTextColorGray range:NSMakeRange(0, lastEventDescription.length)];
            self.lastEventDescription.attributedText = lastEventDescription;
        }
        else
        {
            self.lastEventDescription.text = roomCellData.lastEventTextMessage;
        }
        
        // Notify unreads and bing
        if (roomCellData.hasUnread)
        {
            self.missedNotifAndUnreadIndicator.hidden = NO;
            
            if (0 < roomCellData.notificationCount)
            {
                self.missedNotifAndUnreadIndicator.backgroundColor = roomCellData.highlightCount ? kRiotColorPinkRed : kRiotColorGreen;
                
                self.missedNotifAndUnreadBadgeBgView.hidden = NO;
                self.missedNotifAndUnreadBadgeBgView.backgroundColor = self.missedNotifAndUnreadIndicator.backgroundColor;
                
                self.missedNotifAndUnreadBadgeLabel.text = [NSString stringWithFormat:@"%tu", roomCellData.notificationCount];
                [self.missedNotifAndUnreadBadgeLabel sizeToFit];
                
                self.missedNotifAndUnreadBadgeBgViewWidthConstraint.constant = self.missedNotifAndUnreadBadgeLabel.frame.size.width + 18;
            }
            else
            {
                self.missedNotifAndUnreadIndicator.backgroundColor = kRiotColorSilver;
            }
            
            // Use bold font for the room title
            if ([UIFont respondsToSelector:@selector(systemFontOfSize:weight:)])
            {
                self.roomTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
            }
            else
            {
                self.roomTitle.font = [UIFont boldSystemFontOfSize:17];
            }
        }
        else
        {
            self.lastEventDate.textColor = kRiotTextColorGray;
            
            // The room title is not bold anymore
            if ([UIFont respondsToSelector:@selector(systemFontOfSize:weight:)])
            {
                self.roomTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            }
            else
            {
                self.roomTitle.font = [UIFont systemFontOfSize:17];
            }
        }
        
        self.roomAvatar.backgroundColor = [UIColor clearColor];

        self.directRoomIcon.hidden = !roomCellData.roomSummary.room.isDirect;

        self.encryptedRoomIcon.hidden = !roomCellData.roomSummary.isEncrypted;

        [roomCellData.roomSummary.room setRoomAvatarImageIn:self.roomAvatar];
    }
    else
    {
        self.lastEventDescription.text = @"";
    }
}

+ (CGFloat)heightForCellData:(MXKCellData *)cellData withMaximumWidth:(CGFloat)maxWidth
{
    // The height is fixed
    return 74;
}

@end
