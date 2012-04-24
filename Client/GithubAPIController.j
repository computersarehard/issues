
@import <Foundation/Foundation.j>
@import <AppKit/CPImage.j>
@import "md5-min.js"

BASE_URL = "https://github.com/";
BASE_API = "https://api.github.com";

var SharedController = nil,
    GravatarBaseURL = "http://www.gravatar.com/avatar/";

API_MAX_PER_PAGE = 100;
API_NOTE_VALUE = "GitHub Issues";
API_NOTE_URL = "http://githubissues.heroku.com";

// Sent whenever an issue changes
GitHubAPIIssueDidChangeNotification = @"GitHubAPIIssueDidChangeNotification";
GitHubAPIRepoDidChangeNotification  = "GitHubAPIRepoDidChangeNotification";


CFHTTPRequest.AuthenticationDelegate = function(aRequest)
{
    var sharedController = [GithubAPIController sharedController];

    if (![sharedController isAuthenticated])
        [sharedController promptForAuthentication:nil];
}

@implementation MultiPageRequest : CPObject
{
    CPString            resource;
    int                 maxConcurrentRequests;
    int                 activeRequests;
    CPMutableDictionary pages;
    int                 numberOfPages;
    CPMutableArray      requestQueue;
    var                 completeCallback;
}

- (id)initWithResource:(CPString)aResource maxConcurrentRequests:(int)maxRequests
{
    if (self = [super init])
    {
        resource = aResource;
        maxConcurrentRequests = maxRequests;
        activeRequests = 0;
        pages = [[CPMutableDictionary alloc] init];
        requestQueue = [[CPMutableArray alloc] init];
    }

    return self;
}

- (BOOL)isComplete
{
    return [pages count] === numberOfPages;
}

- (void)loadAllWithCallback:(id)aCallback
{
    completeCallback = aCallback;
    var request = new CFHTTPRequest();
    request.open("GET", resource, true);

    // Get the first page to determine how many pages must be loaded
    request.oncomplete = function()
    {
        if (request.success())
        {
            [pages setObject:JSON.parse(request.responseText()) forKey:0];

            var links = request.getResponseHeader("Link");
            if (links == null)
            {
                numberOfPages = 1;
            }
            else
            {
                var matches = links.match(/<[^>]*?page=(\d+)[^>]*>;\s+rel="last"/);
                if (!matches || matches.length !== 2)
                {
                    throw new Error("Unable to determine number of pages for resource " + resource);
                }
                numberOfPages = parseInt(matches[1]);
            }
        }

        [self queueRequests];
        [self executeRequests];
    };

    request.send("");
}

- (void)executeRequests
{
    if ([self isComplete])
    {
        var allRecords = [[CPMutableArray alloc] init];
        for (var i = 0, len = [pages count]; i < len; i++)
        {
            [allRecords addObjectsFromArray:[pages objectForKey:i]];
        }
        completeCallback(allRecords);
        return;
    }
    for (; activeRequests < maxConcurrentRequests && [requestQueue count] > 0; activeRequests++)
    {
        var task = [requestQueue firstObject];
        [requestQueue removeObjectAtIndex:0];
        task();
    }
}

- (void)requestCompleted
{
    activeRequests--;
    [self executeRequests];
}

- (void)queueRequests
{
    function loadPage (pageIndex) {
        return function()
        {
            var pageNumber = pageIndex + 1;
            var url = resource;
            if (!url.indexOf("?"))
            {
                url += "?page=" + pageNumber;
            }
            else
            {
                url += "&page=" + pageNumber;
            }
            var request = new CFHTTPRequest();
            request.open("GET", url, true);

            request.oncomplete = function ()
            {
                try
                {
                    if (request.success())
                    {
                        [pages setObject:JSON.parse(request.responseText()) forKey:pageIndex];
                    }
                } catch (e)
                {
                    CPLog.error("Unable to process response for " + resource + " page " + pageNumber);
                }
                [self requestCompleted];
            };

            request.send("");
        };
    };
    // Page 1  is always loaded before this is called
    for (var page = 1; page < numberOfPages; page++)
    {
        [requestQueue addObject:loadPage(page)];
    }
}

@end

@implementation GithubAPIController : CPObject
{
    CPString        username @accessors;
    CPString        authenticationToken @accessors;
    CPString        oauthAccessToken @accessors;

    CPString        website @accessors;
    CPString        emailAddress @accessors;
    CPString        emailAddressHashed;
    CPImage         userImage @accessors;
    CPImage         userThumbnailImage @accessors;

    CPDictionary    repositoriesByIdentifier @accessors(readonly);

    OAuthController loginController @accessors;

    CPAlert         warnAlert;
    CPAlert         logoutWarn;

    Function        nextAuthCallback @accessors;
}

+ (id)sharedController
{
    if (!SharedController)
    {
        SharedController = [[super alloc] init];
        [CPURLConnection setClassDelegate:SharedController];
    }

    return SharedController;
}

- (id)init
{
    if (self = [super init])
    {
        repositoriesByIdentifier = [CPDictionary dictionary];
    }

    return self;
}

- (BOOL)isAuthenticated
{
    return [[CPUserSessionManager defaultManager] status] === CPUserSessionLoggedInStatus;
}

- (void)toggleAuthentication:(id)sender
{
    if ([self isAuthenticated])
        [self logout:sender];
    else
        [self promptForAuthentication:sender];
}

- (CPString)URLForPathComponents:(CPArray)aPath JSObjectParameters:(id)parameters
{
    return [self URLForPathComponents:aPath parameters:[CPDictionary dictionaryWithJSObject:parameters]];
}

- (CPString)URLForPathComponents:(CPArray)pathComponents parameters:(CPDictionary)parameters
{
    var path = BASE_API + "/" + [pathComponents componentsJoinedByString:"/"];

    var params = [[CPMutableDictionary alloc] init];
    if (parameters !== nil)
    {
        [params addEntriesFromDictionary:parameters];
    }
    if ([self isAuthenticated])
    {
        [params setObject:oauthAccessToken forKey:"access_token"];
    }

    if ([params count] > 0)
    {
        var paramEntries = [[CPMutableArray alloc] init];

        var keyEnum = [params keyEnumerator];
        var key = nil;
        while ((key = [keyEnum nextObject])) {
            var value = [params objectForKey:key];
            [paramEntries addObject:encodeURIComponent(key) + "=" + encodeURIComponent(value)];
        }

        path += "?" + [paramEntries componentsJoinedByString:"&"];
    }

    return path;
}

- (void)logoutPrompt:(id)sender
{
    // if we're not using OAuth it's a pain to find the
    // API token... so just ask them to make sure

    if (oauthAccessToken)
        return [self logout:nil];

    logoutWarn= [[CPAlert alloc] init];
    [logoutWarn setTitle:"Are You Sure?"];
    [logoutWarn setMessageText:"Are you sure you want to logout?"];
    [logoutWarn setInformativeText:text];
    [logoutWarn setAlertStyle:CPInformationalAlertStyle];
    [logoutWarn addButtonWithTitle:"Cancel"];
    [logoutWarn setDelegate:self];
    [logoutWarn addButtonWithTitle:"Logout"];

    [logoutWarn runModal];
}

- (void)logout:(id)sender
{
    username = nil;
    authenticationToken = nil;
    userImage = nil;
    userThumbnailImage = nil;
    oauthAccessToken = nil;
    [[CPUserSessionManager defaultManager] setStatus:CPUserSessionLoggedOutStatus];
}

- (CPString)_credentialsString
{
    var authString = "";
    if ([self isAuthenticated])
    {
        if (oauthAccessToken)
            authString += "access_token="+encodeURIComponent(oauthAccessToken);
    }

    return authString;
}

- (void)createOrLookupAccessTokenWithPassword:(CPString)password callback:(id)aCallback
{
    var authorizationHeader = "Basic " + CFData.encodeBase64String(username + ":" + password);
    var listRequest = new CFHTTPRequest();
    var createRequest = new CFHTTPRequest();

    listRequest.open("GET", BASE_API + "/authorizations", true);
    listRequest.setRequestHeader("Authorization", authorizationHeader);
    listRequest.oncomplete = function ()
    {
        [self _checkGithubResponse:listRequest];
        if (!listRequest.success())
        {
            CPLog.error("Failed to lookup authorizations --- " + createRequest.status());
            aCallback(false, listRequest);
            return;
        }

        try
        {
            var authorizations = JSON.parse(listRequest.responseText());
            for (var i = 0; i < [authorizations count]; i++)
            {
                var auth = [authorizations objectAtIndex:i];
                if (auth.note_url == API_NOTE_URL)
                {
                    oauthAccessToken = auth.token;
                    aCallback(true);
                    return;
                }
            }

            // did not find an existing token
            createRequest.open("POST", BASE_API + "/authorizations", true);
            createRequest.setRequestHeader("Content-Type", "application/json");
            createRequest.setRequestHeader("Authorization", authorizationHeader);

            createRequest.send(JSON.stringify({scopes: ["repo"], note: API_NOTE_VALUE, note_url: API_NOTE_URL}));
        }
        catch (e)
        {
            CPLog.error("Unexpected error parsing authorizations --- " + e);
        }
    };

    listRequest.send("");

    createRequest.oncomplete = function ()
    {
        [self _checkGithubResponse:createRequest];
        if (!createRequest.success())
        {
            CPLog.error("Failed to create authorizations --- " + createRequest.status());
            aCallback(false, createRequest);
            return;
        }

        try
        {
            var auth = JSON.parse(createRequest.responseText());
            oauthAccessToken = auth.token;

            aCallback(true, createRequest);
        }
        catch (e)
        {
            CPLog.error("Unexpected error parsing create authorization response --- " + e);
        }
    };
}

- (void)authenticateWithCallback:(Function)aCallback
{
    var request = new CFHTTPRequest();

    if (oauthAccessToken)
        request.open("GET", BASE_API + "/user?access_token=" + encodeURIComponent(oauthAccessToken), true);

    request.oncomplete = function()
    {
        if (request.success())
        {
            var response = JSON.parse(request.responseText());

            username = response.login;
            emailAddress = response.email;
            emailAddressHashed = response.gravatar_id || (response.email ? hex_md5(emailAddress) : "");
            website = response.blog;

            if (emailAddressHashed)
            {
                var gravatarURL = GravatarBaseURL + emailAddressHashed;
                userImage = [[CPImage alloc] initWithContentsOfFile:gravatarURL + "?s=68&d=identicon"
                                                               size:CGSizeMake(68, 68)];
                userThumbnailImage = [[CPImage alloc] initWithContentsOfFile:gravatarURL + "?s=22&d=identicon"
                                                                        size:CGSizeMake(24, 24)];
            }

            [[CPUserSessionManager defaultManager] setStatus:CPUserSessionLoggedInStatus];

            if (nextAuthCallback)
                nextAuthCallback();
        }
        else
        {
            username = nil;
            emailAddress = nil;
            emailAddressHashed = nil;
            website = nil;
            userImage = nil;
            oauthAccessToken = nil;

            [[CPUserSessionManager defaultManager] setStatus:CPUserSessionLoggedOutStatus];
        }

        if (aCallback)
            aCallback(request.success());

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send("");
}

- (void)promptForAuthentication:(id)sender
{
    var loginWindow = [LoginWindow sharedLoginWindow];
    [loginWindow makeKeyAndOrderFront:self];
}

- (CPDictionary)repositoryForIdentifier:(CPString)anIdentifier
{
    return [repositoriesByIdentifier objectForKey:anIdentifier];
}

- (void)loadRepositoryWithIdentifier:(CPString)anIdentifier callback:(Function)aCallback
{
    var parts = anIdentifier.split("/");
    if ([parts count] > 2)
        anIdentifier = parts.slice(0, 2).join("/");

    var request = new CFHTTPRequest();
    request.open("GET", [self URLForPathComponents:["repos", anIdentifier] parameters:nil], true);

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];
        var repo = nil;
        if (request.success())
        {
            try {
                repo = JSON.parse(request.responseText());
                repo.identifier = anIdentifier;

                [repositoriesByIdentifier setObject:repo forKey:anIdentifier];
            }
            catch (e) {
                CPLog.error("Unable to load repositority with identifier: "+anIdentifier+" -- "+e);
            }
        }

        if (aCallback)
            aCallback(repo, request);

        if (repo)
        {
            [self loadLabelsForRepository:repo];
        }

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send("");
}

- (void)loadIssuesInState:(CPString)state forRepository:(Repository)aRepo callback:(id)aCallback
{
    if (state !== "open" && state !== "closed")
    {
        CPLog.error("Invalid issue state " + state);
        aCallback(false, issues);
        return;
    }
    var issuesRequest = [[MultiPageRequest alloc] initWithResource:[self URLForPathComponents:["repos", aRepo.identifier, "issues"]
                                                                           JSObjectParameters:{"state": state, "per_page": API_MAX_PER_PAGE}]
                                             maxConcurrentRequests:3];

    [issuesRequest loadAllWithCallback:function (rawIssues)
    {
        var issues = [CPArray arrayWithJSArray:rawIssues recursively:YES];

        for (var i = 0, count = [issues count]; i < count; i++)
        {
            var issue = issues[i];
            [issue setObject:([issue valueForKeyPath:"pull_request.html_url"] !== [CPNull null]) forKey:"has_pull_request"];
        }

        if (state === "open")
        {
            aRepo.openIssues = issues;
        }
        else if (state === "closed")
        {
            aRepo.closedIssues = issues;
        }

        [self _noteRepoChanged:aRepo];

        if (aCallback)
        {
            aCallback(true, issues);
        }
    }];
}

- (void)loadIssuesForRepository:(Repository)aRepo callback:(id)aCallback
{
    var openIssuesLoaded = NO,
        openIssuesSuccess = NO,
        closedIssuesLoaded = NO,
        closedIssuesSuccess = NO,
        waitForAll = function () {
            if (!openIssuesLoaded || !closedIssuesLoaded)
                return;

            if (aCallback)
                aCallback(openIssuesSuccess && closedIssuesSuccess, aRepo);

            [[CPRunLoop currentRunLoop] performSelectors];
        };

    [self loadIssuesInState:"open" forRepository:aRepo callback:function (wasSuccessful, issues)
    {
        openIssuesLoaded = YES;
        openIssuesSuccess = wasSuccessful;

        waitForAll();
    }];

    [self loadIssuesInState:"closed" forRepository:aRepo callback:function (wasSuccessful, issues)
    {
        closedIssuesLoaded = YES;
        closedIssuesSuccess = wasSuccessful;

        waitForAll();
    }];
}

- (void)loadCommentsForIssue:(Issue)anIssue repository:(Repository)aRepo callback:(Function)aCallback
{
    var request = new CFHTTPRequest();
    request.open("GET", [self URLForPathComponents:["repos", aRepo.identifier, "issues", [anIssue objectForKey:"number"], "comments"] parameters:nil], true);

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];
        var comments = [];
        if (request.success())
        {
            try {
                comments = JSON.parse(request.responseText());
            }
            catch (e) {
                CPLog.error("Unable to load comments for issue: "+anIssue+" -- "+e);
            }
        }

        [anIssue setObject:comments forKey:"all_comments"];

        if (aCallback)
            aCallback(comments, anIssue, aRepo, request)

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send("");
}

- (void)loadLabelsForRepository:(Repository)aRepo
{
    var request = new CFHTTPRequest();
    request.open(@"GET", [self URLForPathComponents:["repos", aRepo.identifier, "labels"] parameters:nil], YES);

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];
        var labels = [];
        if (request.success())
        {
            try
            {
                labels = [CPArray arrayWithJSArray:(JSON.parse(request.responseText()) || []) recursively:YES];
            }
            catch (e)
            {
                CPLog.error(@"Unable to load labels for repository: " + aRepo.identifier + @" -- " + e);
            }
        }

        aRepo.labels = labels;
        [[CPRunLoop currentRunLoop] performSelectors];
    };

    request.send(@"");
}

- (void)createLabel:(CPString)aLabel withColor:(CPColor)aColor repository:(Repository)aRepo callback:(id)callback
{
    var existingLabels = [aRepo.labels valueForKeyPath:"name"];
    if ([existingLabels containsObject:aLabel])
    {
        callback(true);
        return;
    }

    var request = new CFHTTPRequest();
    request.open("POST", [self URLForPathComponents:["repos", aRepo.identifier, "labels"] parameters:nil], true);

    request.oncomplete = function ()
    {
        [self _checkGithubResponse:request];
        if (request.success())
        {
            try
            {
                var label = [CPDictionary dictionaryWithJSObject:JSON.parse(request.responseText()) recursively:YES];
                [aRepo.labels addObject:label];
                [self _noteRepoChanged:aRepo];
                callback(true);
                return;
            }
            catch (e)
            {
                CPLog.error("Created label " + aLabel + " in repository " + aRepo.identifier + " but failed to parse response from server." + e);
            }
        }
        callback(false);
    };

    request.send(JSON.stringify({name: aLabel, color:[aColor hexString]}));
}

- (void)label:(CPString)aLabel forIssue:(Issue)anIssue repository:(Repository)aRepo shouldRemove:(BOOL)shouldRemove
{
    var request = new CFHTTPRequest();

    var labelNames = [anIssue valueForKeyPath:"labels.name"] || [];
    if ([labelNames count] === 0 && shouldRemove)
        return;

    if ([aRepo.labels count] === 0)
    {
        CPLog.error("No labels configured for repository " + aRepo.identifier);
        return;
    }

    if (shouldRemove)
    {
        [labelNames removeObject:aLabel];
    }
    else
    {
        var repoLabels = [aRepo.labels valueForKeyPath:"name"];
        if ([repoLabels containsObject:aLabel] === NO)
        {
            CPLog.error("Label " + aLabel + " not configured for repository " + aRepo.identifier);
            return;
        }
        [labelNames addObject:aLabel];
    }

    request.open(@"PUT", [self URLForPathComponents:["repos", aRepo.identifier, "issues", [anIssue objectForKey:"number"], "labels"] parameters:nil], true);
    request.setRequestHeader("Content-Type", "application/json");

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];
        if (request.success())
        {
            try
            {
                // returns all the labels for the issue it was assigned to
                var labels = [CPArray arrayWithJSArray:(JSON.parse(request.responseText()) || []) recursively:YES];
                [anIssue setObject:labels forKey:@"labels"];
                [self _noteIssueChanged:anIssue];
            }
            catch (e)
            {
                CPLog.error(@"Unable to set labels for issue: " + [anIssue objectForKey:"number"] + @" -- " + e);
            }
        }

        [[CPRunLoop currentRunLoop] performSelectors];
    };

    request.send(JSON.stringify(labelNames));
}

- (void)closeIssue:(id)anIssue repository:(id)aRepo callback:(Function)aCallback
{
    var request = new CFHTTPRequest();
    request.open("PATCH", [self URLForPathComponents:["repos", aRepo.identifier, "issues", [anIssue objectForKey:"number"]] parameters:nil], true);

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];

        if (request.success())
        {
            [anIssue setObject:"closed" forKey:"state"];
            [aRepo.openIssues removeObject:anIssue];
            [aRepo.closedIssues addObject:anIssue];

            [self _noteRepoChanged:aRepo];
            [self _noteIssueChanged:anIssue];
        }

        if (aCallback)
            aCallback(request.success(), anIssue, aRepo, request);

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send(JSON.stringify({state: "closed"}));
}

- (void)reopenIssue:(id)anIssue repository:(id)aRepo callback:(Function)aCallback
{
    var request = new CFHTTPRequest();
    request.open("PATCH", [self URLForPathComponents:["repos", aRepo.identifier, "issues", [anIssue objectForKey:"number"]] parameters:nil], true);

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];

        if (request.success())
        {
            [anIssue setObject:"open" forKey:"state"];
            [aRepo.closedIssues removeObject:anIssue];
            [aRepo.openIssues addObject:anIssue];

            [self _noteRepoChanged:aRepo];
            [self _noteIssueChanged:anIssue];
        }

        if (aCallback)
            aCallback(request.success(), anIssue, aRepo, request);

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send(JSON.stringify({state: "open"}));
}

- (void)openNewIssueWithTitle:(CPString)aTitle body:(CPString)aBody repository:(id)aRepo callback:(Function)aCallback
{
    var request = new CFHTTPRequest();
    request.open("POST", [self URLForPathComponents:["repos", aRepo.identifier, "issues"] parameters:nil], true);

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];

        if (request.success())
        {
            var issue = nil;
            try {
                issue = [CPDictionary dictionaryWithJSObject:JSON.parse(request.responseText()) recursively:YES];
                [aRepo.openIssues addObject:issue];

                [self _noteRepoChanged:aRepo];
            }
            catch (e) {
                CPLog.error("Unable to open new issue: "+aTitle+" -- "+e);
            }
        }

        if (aCallback)
            aCallback(issue, aRepo, request);

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send(JSON.stringify({title: aTitle, body: aBody}));
}

- (void)addComment:(CPString)commentBody onIssue:(id)anIssue inRepository:(id)aRepo callback:(Function)aCallback
{
    var request = new CFHTTPRequest();
    request.open("POST", [self URLForPathComponents:["repos", aRepo.identifier, "issues", [anIssue objectForKey:"number"], "comments"] parameters:nil], true);
    request.setRequestHeader("Content-Type", "application/json");

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];

        var comment = nil;

        if (request.success())
        {
            try {
                comment = JSON.parse(request.responseText());

                var comments = [anIssue objectForKey:"all_comments"];

                comment.body_html = Markdown.makeHtml(comment.body || "");
                comment.human_readable_date = [CPDate simpleDate:comment.created_at];

                comments.push(comment);

                [self _noteIssueChanged:anIssue];
            }
            catch (e) {
                CPLog.error("Unable to load comments for issue: "+anIssue+" -- "+e);
            }
        }

        if (aCallback)
            aCallback(comment, request);

            [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send(JSON.stringify({body: commentBody}));
}

- (void)editIsssue:(Issue)anIssue title:(CPString)aTitle body:(CPString)aBody repository:(id)aRepo callback:(Function)aCallback
{
    // we've got to make two calls one for the title and one for the body
    var request = new CFHTTPRequest();
    request.open("PATCH", [self URLForPathComponents:["repos", aRepo.identifier, "issues", [anIssue objectForKey:"number"]] parameters:nil], true);
    request.setRequestHeader("Content-Type", "application/json");

    request.oncomplete = function()
    {
        [self _checkGithubResponse:request];

        if (request.success())
        {
            var issue = nil;
            try {
                issue = [CPDictionary dictionaryWithJSObject:JSON.parse(request.responseText())];

                [anIssue setObject:[issue objectForKey:"title"] forKey:"title"];
                [anIssue setObject:[issue objectForKey:"body"] forKey:"body"];
                [anIssue setObject:[issue objectForKey:"updated_at"] forKey:"updated_at"];

                [self _noteIssueChanged:anIssue];
            }
            catch (e) {
                CPLog.error("Unable to open new issue: "+aTitle+" -- "+e);
            }
        }

        if (aCallback)
            aCallback(issue, aRepo, request);

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send(JSON.stringify({title: aTitle, body:aBody}));
}

/*
because one day maybe GitHub will give this to me... :) 
- (void)setPositionForIssue:(id)anIssue inRepository:(id)aRepo to:(int)aPosition callback:(Function)aCallback
{
    var request = new CFHTTPRequest();
    request.open("POST", BASE_API+"issues/edit/"+aRepo.identifier+"/"+[anIssue objectForKey:"number"]+[self _credentialsString]+"&position="+encodeURIComponent(aPosition), true);

    request.oncomplete = function()
    {
        if (request.success())
        {
            // not really sure what we need to do here
            // I'm getting false back...
        }

        if (aCallback)
            aCallback(request.success(), anIssue, aRepo, request);

        [[CPRunLoop currentRunLoop] performSelectors];
    }

    request.send("");
}*/

- (void)_noteIssueChanged:(id)anIssue
{
    [[CPNotificationCenter defaultCenter] postNotificationName:GitHubAPIIssueDidChangeNotification
                                                        object:anIssue
                                                      userInfo:nil];
}

- (void)_noteRepoChanged:(id)aRepo
{
    [[CPNotificationCenter defaultCenter] postNotificationName:GitHubAPIRepoDidChangeNotification
                                                        object:nil
                                                      userInfo:nil];
}

- (void)_checkGithubResponse:(CFHTTPRequest)aRequest
{
    function showAlert(title, messageText, informativeText, style, buttonTitle)
    {
        var noteAlert = [[CPAlert alloc] init];

        [noteAlert setTitle:title];
        [noteAlert setMessageText:messageText];
        [noteAlert setInformativeText:informativeText];
        [noteAlert setAlertStyle:style];
        [noteAlert addButtonWithTitle:buttonTitle];
        [noteAlert runModal];
    }
    // FIXME v3 of the API no longer returns 401, instead it returns 404...
    if (aRequest.status() === 401)
    {
        try
        {
            // we got a 401 from something else... o.0
            if (JSON.parse(aRequest.responseText()).error !== "not authorized")
                return;
            else
            {
                var auth = [self isAuthenticated],
                    text = (auth) ? "Make sure your account has sufficient privileges to modify an issue or reposotory. " : "The action you tried to perfom requires you to be authenticated. Please login.";

                // this way we only get one alert at a time
                if (!warnAlert)
                {
                    warnAlert = [[CPAlert alloc] init];
                    [warnAlert setTitle:"Not Authorized"];
                    [warnAlert setMessageText:"Unauthorized Request"];
                    [warnAlert setInformativeText:text];
                    [warnAlert setAlertStyle:CPInformationalAlertStyle];
                    [warnAlert addButtonWithTitle:"Okay"];
                    [warnAlert setDelegate:self];

                    if (!auth)
                        [warnAlert addButtonWithTitle:"Login"];
                }

                [warnAlert runModal];
            }
        }catch(e){}
    }
    // 400 and 422 are currently the only statuses documented in the API
    else if (aRequest.status() === 404 || aRequest.status() === 400 || aRequest.status() === 422)
    {
        var error = nil;
        try
        {
            error = JSON.parse(aRequest.responseText()).message;
        } catch (e)
        {
            error = aRequest.responseText();
        }
        showAlert("Error",
                "Error",
                "An error occurred while accessing the GitHub API. GitHub error:" + error,
                CPWarningAlertStyle,
                "Okay");
    }
    else if (aRequest.status() === 503)
    {
        showAlert("Service Unavailable",
                "Service Unavailable",
                "It appears the GitHub API is down at the moment. Check back in a few minutes to see if it is back online.",
                CPWarningAlertStyle,
                "Okay");
    }
}

- (void)alertDidEnd:(id)sender returnCode:(int)returnCode
{
    if (sender === warnAlert && returnCode === 1)
        [self promptForAuthentication:self];
    else if (sender === logoutWarn && returnCode === 1)
        [self logout:nil];
}
@end

// expose root level interface, for accessing from the iframes
GitHubAPI = {
    addComment: function(commentBody, anIssue, aRepo, callback)
    {
        [SharedController addComment:commentBody
                             onIssue:anIssue
                        inRepository:aRepo
                            callback:callback];
    },

    closeIssue: function(anIssue, aRepo, callback)
    {
        [SharedController closeIssue:anIssue
                          repository:aRepo
                            callback:callback];
    },

    reopenIssue: function(anIssue, aRepo, callback)
    {
        [SharedController reopenIssue:anIssue
                           repository:aRepo
                            callback:callback];
    },

    openEditWindow: function(anIssue, aRepo)
    {
        [[[CPApp delegate] issuesController] editIssue:anIssue repo:aRepo];
    }
}

@implementation CPNull (compare)
- (CPComparisonResult)compare:(id)anObj
{
    if (self === anObj)
        return CPOrderedSame;

    return CPOrderedAscending;
}
@end

@implementation CPArray (WithJSArray)
+ (CPArray)arrayWithJSArray:(id)jsArray recursively:(id)recursively
{
    if (jsArray == nil)
    {
        return nil;
    }
    if (recursively === false)
    {
        return [CPArray arrayWithArray:jsArray];
    }

    var cpArray = [[CPArray alloc] init];
    for (var i = 0; i < jsArray.length; i++)
    {
        var value = jsArray[i];
        if (value.constructor === Object)
        {
            [cpArray addObject:[CPDictionary dictionaryWithJSObject:value recursively:recursively]];
        }
        else if ([value isKindOfClass:CPArray])
        {
            [cpArray addObject:[CPArray arrayWithJSArray:value recursively:recursively]];
        }
    }
    return cpArray;
}
