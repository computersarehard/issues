
@import <Foundation/CPObject.j>

@implementation OctoWindow : CPWindow
{
    @outlet CPTextField welcomeLabel @accessors;
    @outlet CPView      borderView @accessors;
    @outlet CPTextField errorMessageField @accessors;
    @outlet CPView      progressIndicator @accessors;
    @outlet CPButton    defaultButton;
    @outlet CPButton    cancelButton;
}

- (void)awakeFromCib
{
    [borderView setBackgroundColor:[CPColor lightGrayColor]];
    [welcomeLabel setFont:[CPFont systemFontOfSize:22.0]];
    [errorMessageField setTextColor:[CPColor redColor]];
}

- (id)initWithContentRect:(CGRect)aRect styleMask:(unsigned)aMask
{
    if (self = [super initWithContentRect:aRect styleMask:0])
    {
        [self center];
        [self setMovableByWindowBackground:YES];
        [cancelButton setKeyEquivalent:CPEscapeFunctionKey];
    }

    return self;
}

- (@action)orderFront:(id)sender
{
    [super orderFront:sender];
    [errorMessageField setHidden:YES];
    [progressIndicator setHidden:YES];
}

- (void)setDefaultButton:(CPButton)aButton
{
    [super setDefaultButton:aButton];
    defaultButton = aButton;
}

@end

var SharedLoginWindow = nil;

@implementation LoginWindow : OctoWindow
{
    @outlet CPTextField usernameField @accessors;
    @outlet CPTextField apiTokenField @accessors;
    @outlet CPButton    apiTokenHelpButton @accessors;
}

+ (id)sharedLoginWindow
{
    return SharedLoginWindow;
}

- (void)awakeFromCib
{
    SharedLoginWindow = self;
    [super awakeFromCib];

    var passwordField = [[CPSecureTextField alloc] initWithFrame:[apiTokenField frame]];
    [passwordField setEditable:YES];
    [passwordField setBordered:YES];
    [passwordField setBezeled:YES];
    [[CPNotificationCenter defaultCenter] addObserver:self selector:@selector(controlTextDidChange:) name:CPControlTextDidChangeNotification object:passwordField];

    [usernameField setNextKeyView:passwordField];
    [passwordField setNextKeyView:defaultButton];

    [[CPNotificationCenter defaultCenter] removeObserver:apiTokenField];
    [[apiTokenField superview] replaceSubview:apiTokenField with:passwordField];

    apiTokenField = passwordField;

    [apiTokenHelpButton removeFromSuperview];
    apiTokenHelpButton = nil;

    var views = [[apiTokenField superview] subviews];
    for (var i = 0; i < [views count]; i++) {
        var view = [views objectAtIndex:i];
        if ([view isKindOfClass:CPTextField] && [view stringValue] === "API Token:")
        {
            [view setStringValue:"Password:"];
            break;
        }
    }
}

- (@action)openAPIKeyPage:(id)sender
{
    OPEN_LINK(BASE_URL + "account#admin_bucket");
}

- (@action)orderFront:(id)sender
{
    [super orderFront:sender];
    [usernameField setStringValue:""];
    [apiTokenField setStringValue:""];

    if ([CPPlatform isBrowser])
        [defaultButton setEnabled:NO];
}

- (@action)login:(id)sender
{
    var password = [apiTokenField stringValue];
    [apiTokenField setStringValue:""];

    var githubController = [GithubAPIController sharedController];
    [githubController setUsername:[[self usernameField] stringValue]];
    [githubController createOrLookupAccessTokenWithPassword:password callback:function(success)
    {
        if (!success)
        {
            [progressIndicator setHidden:YES];
            [errorMessageField setHidden:NO];
            [defaultButton setEnabled:YES];
            [cancelButton setEnabled:YES];
            return;
        }

        [githubController authenticateWithCallback:function(success)
        {
            [progressIndicator setHidden:YES];
            [errorMessageField setHidden:success];
            [defaultButton setEnabled:YES];
            [cancelButton setEnabled:YES];

            if (success)
            {
                [[[NewRepoWindow sharedNewRepoWindow] errorMessageField] setHidden:YES];
                [self orderOut:self];
            }
        }];
    }];

    
    [errorMessageField setHidden:YES];
    [progressIndicator setHidden:NO];
    [defaultButton setEnabled:NO];
    [cancelButton setEnabled:NO];
}

- (void)controlTextDidChange:(CPNotification)aNote
{
    if (![CPPlatform isBrowser] || ([aNote object] !== apiTokenField && [aNote object] !== usernameField))
        return;

    if (![usernameField stringValue] || ![apiTokenField stringValue])
        [defaultButton setEnabled:NO];
    else
        [defaultButton setEnabled:YES];
}

@end

var SharedRepoWindow = nil;

@implementation NewRepoWindow : OctoWindow
{
    @outlet CPTextField identifierField @accessors;
    @outlet RepositoriesController repoController;
}

+ (id)sharedNewRepoWindow
{
    return SharedRepoWindow;
}

- (void)awakeFromCib
{
    SharedRepoWindow = self;
    [super awakeFromCib];
    [identifierField setValue:[CPColor grayColor] forThemeAttribute:"text-color" inState:CPTextFieldStatePlaceholder];
}

- (void)controlTextDidChange:(CPNotification)aNote
{
    if ([aNote object] !== identifierField)
        return;

    if (![identifierField stringValue])
        [defaultButton setEnabled:NO];
    else
        [defaultButton setEnabled:YES];
}

- (@action)orderFront:(id)sender
{
    [super orderFront:sender];
    [identifierField setStringValue:""];
    [defaultButton setEnabled:NO];
}

- (@action)addRepository:(id)sender
{
    var repoIdentifier = [identifierField stringValue];
    if (!repoIdentifier)
        return;

    var existingRepo = [[GithubAPIController sharedController] repositoryForIdentifier:repoIdentifier];
    if (existingRepo)
    {
        [repoController addRepository:existingRepo];
        [self orderOut:self];
        return;
    }

    [[GithubAPIController sharedController] loadRepositoryWithIdentifier:repoIdentifier callback:function(repo)
    {
        [progressIndicator setHidden:YES];
        [errorMessageField setHidden:!!repo];
        [defaultButton setEnabled:YES];
        [cancelButton setEnabled:YES];

        if (repo)
        {
            [repoController addRepository:repo];
            [self orderOut:self];
        }
    }];    

    [errorMessageField setHidden:YES];
    [progressIndicator setHidden:NO];
    [defaultButton setEnabled:NO];
    [cancelButton setEnabled:NO];
}

- (void)sendEvent:(CPEvent)anEvent
{
    if ([anEvent type] === CPKeyUp && [anEvent keyCode] === CPTabKeyCode)
        [self makeFirstResponder:identifierField];
    else
        [super sendEvent:anEvent];
}

@end
